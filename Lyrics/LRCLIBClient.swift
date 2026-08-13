import Foundation

struct LRCLine: Equatable {
    let time: TimeInterval
    let text: String
}

struct LRCLyrics {
    let lines: [LRCLine]
    let plain: String?

    func currentLine(at position: TimeInterval) -> (current: LRCLine?, next: LRCLine?) {
        guard !lines.isEmpty else { return (nil, nil) }
        var currentIndex: Int?
        for (index, line) in lines.enumerated() {
            if line.time <= position {
                currentIndex = index
            } else {
                break
            }
        }
        guard let currentIndex else { return (nil, lines.first) }
        let next = currentIndex + 1 < lines.count ? lines[currentIndex + 1] : nil
        return (lines[currentIndex], next)
    }
}

enum LRCLIBError: Error {
    case notFound
    case invalidResponse
}

/// Free, no-key synced-lyrics lookup: https://lrclib.net/docs
final class LRCLIBClient {
    private let session = URLSession.shared
    private var cache: [String: LRCLyrics] = [:]

    func fetchLyrics(trackName: String, artistName: String) async throws -> LRCLyrics {
        let cacheKey = "\(artistName.lowercased())::\(trackName.lowercased())"
        if let cached = cache[cacheKey] { return cached }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: trackName),
            URLQueryItem(name: "artist_name", value: artistName)
        ]

        guard let url = components.url else { throw LRCLIBError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("LyricsApp/1.0 (personal project)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LRCLIBError.invalidResponse }
        guard http.statusCode == 200 else { throw LRCLIBError.notFound }

        let decoded = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
        let lyrics = Self.parse(decoded)
        cache[cacheKey] = lyrics
        return lyrics
    }

    private static func parse(_ response: LRCLIBResponse) -> LRCLyrics {
        guard let synced = response.syncedLyrics, !synced.isEmpty else {
            return LRCLyrics(lines: [], plain: response.plainLyrics)
        }

        let lines: [LRCLine] = synced.split(separator: "\n").compactMap { rawLine in
            parseLRCLine(String(rawLine))
        }
        return LRCLyrics(lines: lines, plain: response.plainLyrics)
    }

    /// Parses a single "[mm:ss.xx]lyric text" line.
    private static func parseLRCLine(_ line: String) -> LRCLine? {
        guard line.hasPrefix("["), let closeIndex = line.firstIndex(of: "]") else { return nil }
        let timeString = line[line.index(after: line.startIndex)..<closeIndex]
        let text = String(line[line.index(after: closeIndex)...]).trimmingCharacters(in: .whitespaces)

        let parts = timeString.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }

        return LRCLine(time: minutes * 60 + seconds, text: text)
    }
}

private struct LRCLIBResponse: Codable {
    let trackName: String?
    let artistName: String?
    let plainLyrics: String?
    let syncedLyrics: String?
}
