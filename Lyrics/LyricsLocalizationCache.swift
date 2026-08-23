import Foundation

/// Persisted on disk, unlike LRCLIBClient's in-memory-only cache — that one
/// only needs to survive within a single continuous foreground session, but
/// translation costs real Gemini quota and the same songs get replayed
/// across different drives/days after the app has been killed and
/// relaunched, so this needs to survive that.
struct CachedLocalization: Codable {
    var transliteratedLines: [String]?
    var translatedLines: [String]?
    var transliteratedPlain: String?
    var translatedPlain: String?
}

final class LyricsLocalizationCache {
    private let fileURL: URL
    private var store: [String: CachedLocalization] = [:]
    private let ioQueue = DispatchQueue(label: "com.jayant.lyrics.localization-cache", qos: .utility)

    init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("lyrics_localization_cache.json")
        load()
    }

    /// Blocks until any in-flight `persist()` write has completed. Only
    /// meaningful in tests, which need the on-disk file to be up to date
    /// before reading it back with a fresh instance — production code never
    /// needs to wait on the write since `store` (the in-memory source of
    /// truth) is already updated synchronously before `persist()` is called.
    func waitForPendingWrites() {
        ioQueue.sync {}
    }

    private func key(track: String, artist: String) -> String {
        "\(artist.lowercased())::\(track.lowercased())"
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        store = (try? JSONDecoder().decode([String: CachedLocalization].self, from: data)) ?? [:]
    }

    private func persist() {
        let snapshot = store
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func get(track: String, artist: String) -> CachedLocalization? {
        store[key(track: track, artist: artist)]
    }

    func setTransliterated(lines: [String]?, plain: String?, track: String, artist: String) {
        let k = key(track: track, artist: artist)
        var entry = store[k] ?? CachedLocalization()
        entry.transliteratedLines = lines
        entry.transliteratedPlain = plain
        store[k] = entry
        persist()
    }

    func setTranslated(lines: [String]?, plain: String?, track: String, artist: String) {
        let k = key(track: track, artist: artist)
        var entry = store[k] ?? CachedLocalization()
        entry.translatedLines = lines
        entry.translatedPlain = plain
        store[k] = entry
        persist()
    }
}
