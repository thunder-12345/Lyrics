import Foundation

/// Fallback for tracks LRCLIB doesn't have. Free, no key, but plain/unsynced
/// text only — used only when LRCLIB comes back empty, since it has no
/// timestamp data to sync display to playback.
final class LyricsOvhClient {
    private let session = URLSession.shared

    func fetchPlainLyrics(trackName: String, artistName: String) async throws -> String {
        guard let encodedArtist = artistName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTrack = trackName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTrack)") else {
            throw LRCLIBError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LRCLIBError.notFound
        }

        let decoded = try JSONDecoder().decode(LyricsOvhResponse.self, from: data)
        return decoded.lyrics
    }
}

private struct LyricsOvhResponse: Codable {
    let lyrics: String
}
