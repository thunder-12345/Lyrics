import Foundation
import NaturalLanguage

@MainActor
final class LyricsSyncEngine: ObservableObject {
    @Published var statusText = "Waiting for a match…"
    @Published var currentLine = ""
    @Published var nextLine = ""
    @Published var isEnglishDetected = false
    @Published var isTranslating = false
    @Published var displayMode: LyricsDisplayMode = LyricsSyncEngine.loadSavedDisplayMode() {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Self.displayModeDefaultsKey)
            if displayMode == .translated || displayMode == .combined {
                triggerTranslationIfNeeded()
            }
            // Reflect the switch immediately rather than waiting for the
            // next tick -- effectiveLyrics() falls back to Original on its
            // own if the newly-selected mode isn't ready yet.
            if let match = currentMatch, !isPaused {
                updateDisplayedLyrics(match: match)
                pushLiveActivityIfNeeded(match: match, isPaused: false)
            }
        }
    }

    private static let displayModeDefaultsKey = "com.jayant.lyrics.displayMode"

    private static func loadSavedDisplayMode() -> LyricsDisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: displayModeDefaultsKey),
              let mode = LyricsDisplayMode(rawValue: raw) else { return .original }
        return mode
    }

    private let gistClient = NowPlayingGistClient()
    private let lrclib = LRCLIBClient()
    private let lyricsOvh = LyricsOvhClient()
    private let liveActivity = LiveActivityController()
    private let localizationCache = LyricsLocalizationCache()
    private let translator = GeminiTranslationClient()
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    private var transliteratedLyrics: LRCLyrics?
    private var translatedLyrics: LRCLyrics?
    private var translationTask: Task<Void, Never>?

    private var currentMatch: TrackMatch?
    private var currentLyrics: LRCLyrics?
    private var isPaused = true
    /// Tracks what was last actually pushed to the Live Activity so tick()
    /// can skip redundant calls. ActivityKit still has some update-rate
    /// tolerance for genuinely-changed content — this just avoids wasting
    /// calls on identical content, not a fix for the deeper throttle that
    /// kicks in after a while regardless (that needs push notifications,
    /// which need the paid Developer Program — not pursued here).
    private var lastPushedLine: String?
    private var lastPushedNextLine: String?
    private var lastPushedIsPaused: Bool?
    private weak var keepAlive: SilentAudioKeepAlive?

    /// Normal poll cadence is 1s — the gist read is unconditional every tick,
    /// so this is the main lever on GitHub's 5,000 req/hr budget (already
    /// ~72% used by 1s polling alone). Burst polling trades a few seconds of
    /// faster polling per song, right at the boundary, for much lower
    /// transition latency, without raising the steady-state rate.
    private let normalPollInterval: TimeInterval = 1
    private let burstPollInterval: TimeInterval = 0.25
    /// Start bursting once this little of the track is left.
    private let burstPollThreshold: TimeInterval = 2
    /// Hard cap on how long a burst can run, in case duration/elapsed data
    /// is stale or wrong and the expected track change never arrives.
    private let burstPollSafetyWindow: TimeInterval = 6
    private var isBurstPolling = false
    private var burstPollDeadline: Date?
    private var trackDetectedAt: Date?
    private var firstLyricPushLoggedForTrack: String?
    /// Position (seconds into the track) at the moment a pause was first
    /// confirmed. The Mac's elapsedSeconds reading is unreliable right at
    /// the pause/resume boundary (observed to read 0 while genuinely
    /// paused, via MediaRemote/Connect, not the true paused-at position) --
    /// resuming re-anchors from this frozen value instead of trusting
    /// whatever the Mac happens to report on the resume fetch.
    private var pausedAtPosition: Double?

    func start(keepAlive: SilentAudioKeepAlive? = nil) {
        self.keepAlive = keepAlive

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        schedulePollTimer(interval: normalPollInterval)

        Task { await poll() }
    }

    private func schedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    private func startBurstPolling() {
        guard !isBurstPolling else { return }
        isBurstPolling = true
        burstPollDeadline = Date().addingTimeInterval(burstPollSafetyWindow)
        schedulePollTimer(interval: burstPollInterval)
    }

    private func stopBurstPolling() {
        guard isBurstPolling else { return }
        isBurstPolling = false
        burstPollDeadline = nil
        schedulePollTimer(interval: normalPollInterval)
    }

    func stop() {
        tickTimer?.invalidate()
        pollTimer?.invalidate()
        Task { await liveActivity.end() }
    }

    private func poll() async {
        do {
            let fetched = try await gistClient.fetchCurrentTrack()
            await MainActor.run {
                handleFetchedTrack(fetched)
            }
        } catch {
            await MainActor.run {
                statusText = "Couldn't reach the relay: \(error.localizedDescription)"
            }
        }
    }

    private func handleFetchedTrack(_ fetched: TrackMatch?) {
        let wasPaused = isPaused

        guard let fetched else {
            if !isPaused {
                // Just confirmed paused -- freeze the position here rather
                // than trusting elapsedSeconds on the resume fetch later.
                pausedAtPosition = currentMatch?.currentPlaybackPosition()
            }
            isPaused = true
            statusText = "Nothing playing on the Mac right now…"
            return
        }

        isPaused = false
        let isSameTrack = fetched.trackName == currentMatch?.trackName && fetched.artistName == currentMatch?.artistName

        if isSameTrack && !wasPaused {
            // Same track, was already playing — nothing changed, keep the
            // existing anchor rather than resetting position tracking.
            return
        }

        if isSameTrack && wasPaused {
            // Resumed after a pause. Anchor from the position we froze at
            // pause time, counting forward from now, instead of the fresh
            // fetch's own elapsedSeconds -- that reading is unreliable
            // right at the pause/resume boundary and has been observed to
            // come back as 0, which would snap lyrics back to the start of
            // the song. Lyrics don't need re-fetching either way.
            currentMatch = TrackMatch(
                trackName: fetched.trackName,
                artistName: fetched.artistName,
                elapsedSeconds: pausedAtPosition ?? fetched.elapsedSeconds,
                matchedAt: Date(),
                durationSeconds: fetched.durationSeconds
            )
            pausedAtPosition = nil
            return
        }

        pausedAtPosition = nil
        stopBurstPolling()

        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
        transliteratedLyrics = nil
        translatedLyrics = nil
        isEnglishDetected = false

        currentMatch = fetched
        currentLyrics = nil
        currentLine = ""
        nextLine = ""
        lastPushedLine = nil
        lastPushedNextLine = nil
        lastPushedIsPaused = nil
        trackDetectedAt = Date()
        firstLyricPushLoggedForTrack = nil
        statusText = "Now playing: \(fetched.trackName) — \(fetched.artistName)"
        TimingLogger.log("track_detected track=\"\(fetched.trackName)\" artist=\"\(fetched.artistName)\" elapsed=\(String(format: "%.3f", fetched.elapsedSeconds))")
        liveActivity.start(trackName: fetched.trackName, artistName: fetched.artistName)

        Task {
            let lyricsStartedAt = Date()
            TimingLogger.log("lyrics_fetch_started track=\"\(fetched.trackName)\" artist=\"\(fetched.artistName)\"")
            do {
                let lyrics = try await lrclib.fetchLyrics(trackName: fetched.trackName, artistName: fetched.artistName)
                if lyrics.lines.isEmpty && lyrics.plain == nil {
                    TimingLogger.log("lyrics_fetch_empty_fallback_started primary_ms=\(TimingLogger.elapsedMS(since: lyricsStartedAt))")
                    currentLyrics = try await fetchFallbackLyrics(match: fetched)
                } else {
                    currentLyrics = lyrics
                }
                TimingLogger.log("lyrics_ready total_ms=\(TimingLogger.elapsedMS(since: lyricsStartedAt)) synced_lines=\(currentLyrics?.lines.count ?? 0)")
                if let lyrics = currentLyrics { prepareLocalizations(match: fetched, lyrics: lyrics) }
                pushCurrentLyrics()
            } catch {
                TimingLogger.log("lyrics_fetch_failed_fallback_started primary_ms=\(TimingLogger.elapsedMS(since: lyricsStartedAt)) error=\"\(error.localizedDescription)\"")
                do {
                    currentLyrics = try await fetchFallbackLyrics(match: fetched)
                    TimingLogger.log("lyrics_ready_fallback total_ms=\(TimingLogger.elapsedMS(since: lyricsStartedAt))")
                    if let lyrics = currentLyrics { prepareLocalizations(match: fetched, lyrics: lyrics) }
                    pushCurrentLyrics()
                } catch {
                    TimingLogger.log("lyrics_unavailable total_ms=\(TimingLogger.elapsedMS(since: lyricsStartedAt)) error=\"\(error.localizedDescription)\"")
                    statusText = "Matched \(fetched.trackName), but no lyrics found anywhere."
                }
            }
        }
    }

    private func fetchFallbackLyrics(match: TrackMatch) async throws -> LRCLyrics {
        let plain = try await lyricsOvh.fetchPlainLyrics(trackName: match.trackName, artistName: match.artistName)
        return LRCLyrics(lines: [], plain: plain)
    }

    private var currentTrackKey: String? {
        guard let currentMatch else { return nil }
        return "\(currentMatch.trackName)|\(currentMatch.artistName)"
    }

    /// Runs once right after original lyrics are fetched for a track: detects
    /// language (on-device, free) and, if non-English, precomputes the free
    /// ICU transliteration. Translation itself stays lazy -- only triggered
    /// on an actual switch to Translated -- so a song the user never asks to
    /// translate never spends Gemini quota.
    private func prepareLocalizations(match: TrackMatch, lyrics: LRCLyrics) {
        isEnglishDetected = detectIsEnglish(lyrics: lyrics)
        guard !isEnglishDetected else { return }
        loadOrComputeTransliteration(match: match, lyrics: lyrics)
        if displayMode == .translated || displayMode == .combined {
            triggerTranslationIfNeeded()
        }
    }

    /// Permissive on purpose: only a confident English detection counts as
    /// English. Anything else -- including "can't tell", which is common on
    /// short lyric snippets or lines mixing in English words -- leaves the
    /// Transliterated/Translated modes enabled rather than risk hiding a
    /// genuinely useful feature on a false negative.
    private func detectIsEnglish(lyrics: LRCLyrics) -> Bool {
        let sampleText = lyrics.lines.isEmpty
            ? (lyrics.plain ?? "")
            : lyrics.lines.prefix(20).map(\.text).joined(separator: "\n")
        guard !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sampleText)
        return recognizer.dominantLanguage == .english
    }

    private func loadOrComputeTransliteration(match: TrackMatch, lyrics: LRCLyrics) {
        let cached = localizationCache.get(track: match.trackName, artist: match.artistName)

        if lyrics.lines.isEmpty {
            let plain = cached?.transliteratedPlain ?? lyrics.plain.map(Transliterator.transliterate)
            transliteratedLyrics = LRCLyrics(lines: [], plain: plain)
            if cached?.transliteratedPlain == nil {
                localizationCache.setTransliterated(lines: nil, plain: plain, track: match.trackName, artist: match.artistName)
            }
            return
        }

        if let cachedLines = cached?.transliteratedLines, cachedLines.count == lyrics.lines.count {
            let lines = zip(lyrics.lines, cachedLines).map { LRCLine(time: $0.0.time, text: $0.1) }
            transliteratedLyrics = LRCLyrics(lines: lines, plain: nil)
            return
        }

        let lines = Transliterator.transliterate(lines: lyrics.lines)
        transliteratedLyrics = LRCLyrics(lines: lines, plain: nil)
        localizationCache.setTransliterated(lines: lines.map(\.text), plain: nil, track: match.trackName, artist: match.artistName)
    }

    private func triggerTranslationIfNeeded() {
        guard translatedLyrics == nil, translationTask == nil,
              let match = currentMatch, let lyrics = currentLyrics else { return }

        let cached = localizationCache.get(track: match.trackName, artist: match.artistName)
        if !lyrics.lines.isEmpty, let cachedLines = cached?.translatedLines, cachedLines.count == lyrics.lines.count {
            let lines = zip(lyrics.lines, cachedLines).map { LRCLine(time: $0.0.time, text: $0.1) }
            translatedLyrics = LRCLyrics(lines: lines, plain: nil)
            refreshIfShowingTranslated()
            return
        }
        if lyrics.lines.isEmpty, let cachedPlain = cached?.translatedPlain {
            translatedLyrics = LRCLyrics(lines: [], plain: cachedPlain)
            refreshIfShowingTranslated()
            return
        }

        let trackKey = "\(match.trackName)|\(match.artistName)"
        isTranslating = true
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !lyrics.lines.isEmpty {
                    let translated = try await self.translator.translate(segments: lyrics.lines.map(\.text))
                    guard self.currentTrackKey == trackKey else { return }
                    let lines = zip(lyrics.lines, translated).map { LRCLine(time: $0.0.time, text: $0.1) }
                    self.translatedLyrics = LRCLyrics(lines: lines, plain: nil)
                    self.localizationCache.setTranslated(lines: translated, plain: nil, track: match.trackName, artist: match.artistName)
                } else if let plain = lyrics.plain {
                    let translated = try await self.translator.translate(segments: [plain])
                    guard self.currentTrackKey == trackKey else { return }
                    self.translatedLyrics = LRCLyrics(lines: [], plain: translated.first)
                    self.localizationCache.setTranslated(lines: nil, plain: translated.first, track: match.trackName, artist: match.artistName)
                }
                self.refreshIfShowingTranslated()
            } catch {
                TimingLogger.log("translation_failed error=\"\(error.localizedDescription)\"")
            }
            self.isTranslating = false
            self.translationTask = nil
        }
    }

    private func refreshIfShowingTranslated() {
        guard displayMode == .translated || displayMode == .combined,
              let match = currentMatch, !isPaused else { return }
        updateDisplayedLyrics(match: match)
        pushLiveActivityIfNeeded(match: match, isPaused: false)
    }

    private func effectiveLyrics(base: LRCLyrics) -> LRCLyrics {
        switch displayMode {
        case .original:
            return base
        case .transliterated:
            return transliteratedLyrics ?? base
        case .translated:
            return translatedLyrics ?? base
        case .combined:
            return base // combined mode is handled separately in updateDisplayedLyrics
        }
    }

    /// Current-position line lookup that works for both synced (line array)
    /// and unsynced (plain-blob) lyrics, so combined mode can pull from
    /// transliterated/translated sets uniformly regardless of which shape
    /// they're in.
    private func lineText(from lyrics: LRCLyrics?, position: TimeInterval) -> String? {
        guard let lyrics else { return nil }
        if lyrics.lines.isEmpty {
            return lyrics.plain
        }
        return lyrics.currentLine(at: position).current?.text
    }

    private func updateDisplayedLyrics(match: TrackMatch) {
        guard let baseLyrics = currentLyrics else { return }
        let position = match.currentPlaybackPosition()

        if displayMode == .combined {
            let top = lineText(from: transliteratedLyrics, position: position)
                ?? lineText(from: baseLyrics, position: position) ?? ""
            if let bottom = lineText(from: translatedLyrics, position: position) {
                currentLine = "\(top)\n\(bottom)"
            } else {
                currentLine = top
            }
            nextLine = ""
            return
        }

        let lyrics = effectiveLyrics(base: baseLyrics)
        if lyrics.lines.isEmpty {
            currentLine = lyrics.plain ?? ""
            nextLine = "(unsynced lyrics)"
        } else {
            let (current, next) = lyrics.currentLine(at: position)
            currentLine = current?.text ?? ""
            nextLine = next?.text ?? ""
        }
    }

    private func pushCurrentLyrics() {
        guard let match = currentMatch, !isPaused else { return }
        updateDisplayedLyrics(match: match)
        pushLiveActivityIfNeeded(match: match, isPaused: false)
    }

    private func pushLiveActivityIfNeeded(match: TrackMatch, isPaused: Bool) {
        guard currentLine != lastPushedLine || nextLine != lastPushedNextLine || lastPushedIsPaused != isPaused else {
            return
        }
        let trackKey = "\(match.trackName)|\(match.artistName)"
        if !isPaused, !currentLine.isEmpty, firstLyricPushLoggedForTrack != trackKey {
            firstLyricPushLoggedForTrack = trackKey
            let sinceDetectMS = trackDetectedAt.map { TimingLogger.elapsedMS(since: $0) } ?? -1
            TimingLogger.log("first_lyric_push since_detect_ms=\(sinceDetectMS) line=\"\(currentLine)\"")
        }
        lastPushedLine = currentLine
        lastPushedNextLine = nextLine
        lastPushedIsPaused = isPaused

        Task {
            await liveActivity.update(
                trackName: match.trackName,
                artistName: match.artistName,
                currentLine: currentLine,
                nextLine: nextLine,
                isPaused: isPaused
            )
        }
    }

    private func tick() {
        keepAlive?.ensureRunning()

        guard let match = currentMatch else { return }

        if isBurstPolling, let deadline = burstPollDeadline, Date() >= deadline {
            // Expected track change never showed up in time (stale/wrong
            // duration, or the song genuinely just runs long) — fall back to
            // normal cadence rather than burst-polling forever.
            stopBurstPolling()
        } else if !isBurstPolling, !isPaused, let remaining = match.remainingSeconds(), remaining <= burstPollThreshold {
            startBurstPolling()
        }

        if isPaused {
            pushLiveActivityIfNeeded(match: match, isPaused: true)
            return
        }

        updateDisplayedLyrics(match: match)
        pushLiveActivityIfNeeded(match: match, isPaused: false)
    }
}
