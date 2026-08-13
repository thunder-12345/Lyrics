import AVFoundation

/// Plays a programmatically generated, looping silent buffer under the .playback
/// category so the app stays alive in the background long enough for
/// LyricsSyncEngine's timer to keep calling Activity.update(). Standard,
/// App-Store-legal technique — no bundled audio asset needed.
///
/// Handles interruptions and route changes explicitly: a phone call, CarPlay
/// reconnecting, or Bluetooth switching while driving all stop playback, and
/// without resuming it the app can get suspended in the background — which
/// freezes the Live Activity at whatever it last showed until manually
/// reopened.
final class SilentAudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isRunning = false
    /// Debounces ensureRunning()'s restarts. Called every 0.25s from the
    /// sync engine's tick — if engine.isRunning/player.isPlaying ever read
    /// as transiently false (plausible with .mixWithOthers while another
    /// app, e.g. the Spotify clone, is actively sharing the audio session),
    /// restarting the engine that often could itself be what was causing
    /// fast, repeated freezes, rather than fixing anything.
    private var lastRestartAttempt = Date.distantPast
    private let minRestartInterval: TimeInterval = 5

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        startEngine()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
    }

    private func startEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
            let frameCount = AVAudioFrameCount(format.sampleRate) // 1 second, looped
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            // AVAudioPCMBuffer's backing memory starts zeroed — that's already silence.

            if !engine.attachedNodes.contains(player) {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            try engine.start()

            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isRunning = true
        } catch {
            print("SilentAudioKeepAlive failed to start: \(error)")
            isRunning = false
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            isRunning = false
        case .ended:
            startEngine()
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard !isRunning else { return }
        startEngine()
    }

    /// Self-healing check: queries the engine/player's actual live state
    /// rather than trusting our own isRunning flag, and restarts if either
    /// has stopped for any reason — not just the interruption/route-change
    /// cases handled above. Cheap enough to call on every tick. Covers
    /// whatever was causing the Live Activity to freeze specifically on
    /// screen lock, even if the exact iOS-side cause isn't fully known.
    func ensureRunning() {
        guard !engine.isRunning || !player.isPlaying else { return }
        guard Date().timeIntervalSince(lastRestartAttempt) > minRestartInterval else { return }
        lastRestartAttempt = Date()
        startEngine()
    }
}
