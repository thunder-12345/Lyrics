import Foundation

/// Mirrors the JSON written to a private GitHub gist by the Mac-side relay
/// script (mac-relay/update_nowplaying.sh), which reads macOS's system-wide
/// Now Playing info (populated by Spotify Web Player via the standard Media
/// Session API) and relays it here. Sidesteps both the ShazamKit entitlement
/// wall (unobtainable on a free/personal-team account) and the AudD API
/// entirely — no on-device audio capture or recognition at all anymore.
struct TrackMatch: Codable, Equatable {
    let trackName: String
    let artistName: String
    /// The actual in-track position (seconds) at the moment the Mac wrote
    /// this, read from MediaRemote's elapsedTime — not an assumption of 0.
    /// Correctly resumes lyric sync mid-song if a track was already playing
    /// when detected, rather than always starting from the beginning.
    let elapsedSeconds: Double
    /// When the Mac captured elapsedSeconds — the anchor point that, combined
    /// with elapsedSeconds, lets currentPlaybackPosition() extrapolate the
    /// true position without polling continuously.
    let matchedAt: Date
    /// Total track length in seconds, if the Mac could read one. Lets the
    /// sync engine detect an approaching track change and poll faster right
    /// before it happens, instead of waiting for the normal cadence.
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case trackName = "track"
        case artistName = "artist"
        case elapsedSeconds
        case matchedAt = "updatedAt"
        case durationSeconds = "duration"
    }

    func currentPlaybackPosition(now: Date = Date()) -> Double {
        elapsedSeconds + now.timeIntervalSince(matchedAt)
    }

    /// Seconds left in the track, or nil if duration wasn't available.
    func remainingSeconds(now: Date = Date()) -> Double? {
        guard let durationSeconds else { return nil }
        return durationSeconds - currentPlaybackPosition(now: now)
    }
}
