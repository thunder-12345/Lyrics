import XCTest
@testable import Lyrics

final class LyricsLocalizationCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testGetReturnsNilForUnknownEntry() {
        let cache = LyricsLocalizationCache(directory: tempDir)
        XCTAssertNil(cache.get(track: "Unknown", artist: "Nobody"))
    }

    func testSetTransliteratedThenGetReturnsMatchingFields() {
        let cache = LyricsLocalizationCache(directory: tempDir)

        cache.setTransliterated(lines: ["one", "two"], plain: nil, track: "Song", artist: "Artist")

        let entry = cache.get(track: "Song", artist: "Artist")
        XCTAssertEqual(entry?.transliteratedLines, ["one", "two"])
        XCTAssertNil(entry?.transliteratedPlain)
        XCTAssertNil(entry?.translatedLines)
        XCTAssertNil(entry?.translatedPlain)
    }

    func testSettingTranslatedPreservesExistingTransliteratedFields() {
        let cache = LyricsLocalizationCache(directory: tempDir)

        cache.setTransliterated(lines: ["one", "two"], plain: nil, track: "Song", artist: "Artist")
        cache.setTranslated(lines: ["uno", "dos"], plain: nil, track: "Song", artist: "Artist")

        let entry = cache.get(track: "Song", artist: "Artist")
        XCTAssertEqual(entry?.transliteratedLines, ["one", "two"], "Setting translated fields shouldn't clobber transliterated ones")
        XCTAssertEqual(entry?.translatedLines, ["uno", "dos"])
    }

    func testLookupIsCaseInsensitiveOnTrackAndArtist() {
        let cache = LyricsLocalizationCache(directory: tempDir)

        cache.setTransliterated(lines: ["one"], plain: nil, track: "Song Title", artist: "The Artist")

        XCTAssertEqual(cache.get(track: "SONG TITLE", artist: "the artist")?.transliteratedLines, ["one"])
    }

    func testPersistsAcrossInstancesPointedAtTheSameDirectory() {
        let first = LyricsLocalizationCache(directory: tempDir)
        first.setTranslated(lines: nil, plain: "translated plain text", track: "Song", artist: "Artist")
        first.waitForPendingWrites()

        let second = LyricsLocalizationCache(directory: tempDir)

        XCTAssertEqual(second.get(track: "Song", artist: "Artist")?.translatedPlain, "translated plain text")
    }

    func testDistinctTracksDoNotOverwriteEachOther() {
        let cache = LyricsLocalizationCache(directory: tempDir)

        cache.setTransliterated(lines: ["song a lines"], plain: nil, track: "Song A", artist: "Artist")
        cache.setTransliterated(lines: ["song b lines"], plain: nil, track: "Song B", artist: "Artist")

        XCTAssertEqual(cache.get(track: "Song A", artist: "Artist")?.transliteratedLines, ["song a lines"])
        XCTAssertEqual(cache.get(track: "Song B", artist: "Artist")?.transliteratedLines, ["song b lines"])
    }
}
