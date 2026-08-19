import Foundation

enum NowPlayingGistError: Error {
    case invalidResponse
    case missingFile
}

extension NowPlayingGistError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from GitHub Gist"
        case .missingFile:
            return "Missing nowplaying.json in GitHub Gist"
        }
    }
}

/// Polls a private GitHub gist for the current "now playing" state, written
/// by the Mac-side relay script (mac-relay/update_nowplaying.sh) roughly
/// every 5s. Uses the authenticated API endpoint plus a cache-busting query
/// param rather than the raw-content URL, since GitHub's raw-content CDN
/// caches for 5 minutes — far too stale here — and even the API endpoint
/// caches for 60s without busting.
final class NowPlayingGistClient {
    private let session = URLSession.shared
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Returns nil when nothing is currently playing (the relay script
    /// writes empty track/artist strings in that case), not just on error.
    func fetchCurrentTrack() async throws -> TrackMatch? {
        let gistID = try AppConfig.value(for: "NowPlayingGistID")
        let token = try AppConfig.value(for: "GitHubToken")
        let fetchStartedAt = Date()
        var components = URLComponents(string: "https://api.github.com/gists/\(gistID)")!
        components.queryItems = [URLQueryItem(name: "_", value: String(Date().timeIntervalSince1970))]

        guard let url = components.url else { throw NowPlayingGistError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        let networkMS = TimingLogger.elapsedMS(since: fetchStartedAt)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            TimingLogger.log("gist_fetch_failed network_ms=\(networkMS)")
            throw NowPlayingGistError.invalidResponse
        }

        let gist = try JSONDecoder().decode(GistResponse.self, from: data)
        guard let content = gist.files["nowplaying.json"]?.content,
              let contentData = content.data(using: .utf8) else {
            throw NowPlayingGistError.missingFile
        }

        let match = try decoder.decode(TrackMatch.self, from: contentData)
        if match.trackName.isEmpty || match.artistName.isEmpty {
            TimingLogger.log("gist_fetch_empty network_ms=\(networkMS)")
            return nil
        }
        let relayAgeMS = Int(Date().timeIntervalSince(match.matchedAt) * 1000)
        TimingLogger.log("gist_fetch_ok network_ms=\(networkMS) relay_age_ms=\(relayAgeMS) track=\"\(match.trackName)\" artist=\"\(match.artistName)\"")
        return match
    }
}

private struct GistResponse: Codable {
    let files: [String: GistFile]
}

private struct GistFile: Codable {
    let content: String
}
