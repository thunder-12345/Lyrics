import XCTest
@testable import Lyrics

final class LRCLIBClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.requestHandler = nil
        URLProtocolStub.lastRequest = nil
        URLProtocolStub.lastRequestBody = nil
        super.tearDown()
    }

    func testParsesSyncedLinesInOrderWithFractionalSeconds() async throws {
        let json = """
        {"trackName":"Song","artistName":"Artist","plainLyrics":null,"syncedLyrics":\
        "[00:01.50]First line\\n[00:12.00]Second line\\n[01:05.25]Third line"}
        """
        URLProtocolStub.requestHandler = { _ in (200, Data(json.utf8)) }
        let client = LRCLIBClient(session: URLProtocolStub.makeSession())

        let lyrics = try await client.fetchLyrics(trackName: "Song", artistName: "Artist")

        XCTAssertEqual(lyrics.lines, [
            LRCLine(time: 1.5, text: "First line"),
            LRCLine(time: 12.0, text: "Second line"),
            LRCLine(time: 65.25, text: "Third line")
        ])
    }

    func testSkipsMalformedLinesWithoutFailingTheWholeFetch() async throws {
        let json = """
        {"trackName":"Song","artistName":"Artist","plainLyrics":null,"syncedLyrics":\
        "[00:01.00]Good line\\nnot a timed line at all\\n[bad:format]Also bad\\n[00:02.00]Another good line"}
        """
        URLProtocolStub.requestHandler = { _ in (200, Data(json.utf8)) }
        let client = LRCLIBClient(session: URLProtocolStub.makeSession())

        let lyrics = try await client.fetchLyrics(trackName: "Song", artistName: "Artist")

        XCTAssertEqual(lyrics.lines, [
            LRCLine(time: 1.0, text: "Good line"),
            LRCLine(time: 2.0, text: "Another good line")
        ])
    }

    func testFallsBackToPlainLyricsWhenNoSyncedLyricsAvailable() async throws {
        let json = """
        {"trackName":"Song","artistName":"Artist","plainLyrics":"just plain text","syncedLyrics":null}
        """
        URLProtocolStub.requestHandler = { _ in (200, Data(json.utf8)) }
        let client = LRCLIBClient(session: URLProtocolStub.makeSession())

        let lyrics = try await client.fetchLyrics(trackName: "Song", artistName: "Artist")

        XCTAssertTrue(lyrics.lines.isEmpty)
        XCTAssertEqual(lyrics.plain, "just plain text")
    }

    func testThrowsNotFoundOnNon200Status() async throws {
        URLProtocolStub.requestHandler = { _ in (404, Data()) }
        let client = LRCLIBClient(session: URLProtocolStub.makeSession())

        do {
            _ = try await client.fetchLyrics(trackName: "Missing", artistName: "Nobody")
            XCTFail("Expected LRCLIBError.notFound")
        } catch LRCLIBError.notFound {
            // expected
        }
    }

    func testCachesByTrackAndArtistCaseInsensitively() async throws {
        let json = """
        {"trackName":"Song","artistName":"Artist","plainLyrics":null,"syncedLyrics":"[00:01.00]Line"}
        """
        var callCount = 0
        URLProtocolStub.requestHandler = { _ in
            callCount += 1
            return (200, Data(json.utf8))
        }
        let client = LRCLIBClient(session: URLProtocolStub.makeSession())

        _ = try await client.fetchLyrics(trackName: "Song", artistName: "Artist")
        _ = try await client.fetchLyrics(trackName: "SONG", artistName: "artist")

        XCTAssertEqual(callCount, 1, "Second fetch with same track/artist (any case) should hit the cache, not the network")
    }

    func testSendsTrackAndArtistAsQueryParameters() async throws {
        let json = """
        {"trackName":"Song","artistName":"Artist","plainLyrics":null,"syncedLyrics":null}
        """
        URLProtocolStub.requestHandler = { _ in (200, Data(json.utf8)) }
        let client = LRCLIBClient(session: URLProtocolStub.makeSession())

        _ = try await client.fetchLyrics(trackName: "Some Song", artistName: "Some Artist")

        let url = try XCTUnwrap(URLProtocolStub.lastRequest?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["track_name"], "Some Song")
        XCTAssertEqual(items["artist_name"], "Some Artist")
    }
}

final class LRCLyricsCurrentLineTests: XCTestCase {
    private let lyrics = LRCLyrics(lines: [
        LRCLine(time: 10, text: "first"),
        LRCLine(time: 20, text: "second"),
        LRCLine(time: 30, text: "third")
    ], plain: nil)

    func testBeforeFirstLineReturnsNoCurrentButFirstAsNext() {
        let result = lyrics.currentLine(at: 5)
        XCTAssertNil(result.current)
        XCTAssertEqual(result.next, LRCLine(time: 10, text: "first"))
    }

    func testExactlyOnALineTimestampCountsAsCurrent() {
        let result = lyrics.currentLine(at: 20)
        XCTAssertEqual(result.current, LRCLine(time: 20, text: "second"))
        XCTAssertEqual(result.next, LRCLine(time: 30, text: "third"))
    }

    func testBetweenLinesReturnsThePriorLineAsCurrent() {
        let result = lyrics.currentLine(at: 25)
        XCTAssertEqual(result.current, LRCLine(time: 20, text: "second"))
        XCTAssertEqual(result.next, LRCLine(time: 30, text: "third"))
    }

    func testAfterLastLineReturnsItWithNoNext() {
        let result = lyrics.currentLine(at: 999)
        XCTAssertEqual(result.current, LRCLine(time: 30, text: "third"))
        XCTAssertNil(result.next)
    }

    func testEmptyLyricsReturnsNilForBoth() {
        let empty = LRCLyrics(lines: [], plain: nil)
        let result = empty.currentLine(at: 100)
        XCTAssertNil(result.current)
        XCTAssertNil(result.next)
    }
}
