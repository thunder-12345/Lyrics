import Foundation

@MainActor
final class LyricsSyncEngine: ObservableObject {
    @Published var statusText = "Waiting for a match…"
    @Published var currentLine = ""
    @Published var nextLine = ""

    private let gistClient = NowPlayingGistClient()
    private let lrclib = LRCLIBClient()
    private let lyricsOvh = LyricsOvhClient()
    private let liveActivity = LiveActivityController()
    private var tickTimer: Timer?
    private var pollTimer: Timer?

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
                pushCurrentLyrics()
            } catch {
                TimingLogger.log("lyrics_fetch_failed_fallback_started primary_ms=\(TimingLogger.elapsedMS(since: lyricsStartedAt)) error=\"\(error.localizedDescription)\"")
                do {
                    currentLyrics = try await fetchFallbackLyrics(match: fetched)
                    TimingLogger.log("lyrics_ready_fallback total_ms=\(TimingLogger.elapsedMS(since: lyricsStartedAt))")
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

    private func updateDisplayedLyrics(match: TrackMatch) {
        guard let lyrics = currentLyrics else { return }

        if lyrics.lines.isEmpty {
            currentLine = lyrics.plain ?? ""
            nextLine = "(unsynced lyrics)"
        } else {
            let position = match.currentPlaybackPosition()
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
