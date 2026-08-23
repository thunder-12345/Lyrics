import XCTest
@testable import Lyrics

final class LyricsOvhClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.requestHandler = nil
        URLProtocolStub.lastRequest = nil
        URLProtocolStub.lastRequestBody = nil
        super.tearDown()
    }

    func testReturnsLyricsTextOnSuccess() async throws {
        let json = #"{"lyrics":"la la la\nla la la"}"#
        URLProtocolStub.requestHandler = { _ in (200, Data(json.utf8)) }
        let client = LyricsOvhClient(session: URLProtocolStub.makeSession())

        let lyrics = try await client.fetchPlainLyrics(trackName: "Song", artistName: "Artist")

        XCTAssertEqual(lyrics, "la la la\nla la la")
    }

    func testThrowsNotFoundOnNon200Status() async throws {
        URLProtocolStub.requestHandler = { _ in (404, Data()) }
        let client = LyricsOvhClient(session: URLProtocolStub.makeSession())

        do {
            _ = try await client.fetchPlainLyrics(trackName: "Missing", artistName: "Nobody")
            XCTFail("Expected LRCLIBError.notFound")
        } catch LRCLIBError.notFound {
            // expected
        }
    }

    func testPercentEncodesSpacesInThePath() async throws {
        let json = #"{"lyrics":"text"}"#
        URLProtocolStub.requestHandler = { _ in (200, Data(json.utf8)) }
        let client = LyricsOvhClient(session: URLProtocolStub.makeSession())

        _ = try await client.fetchPlainLyrics(trackName: "Song Title", artistName: "The Artist")

        let url = try XCTUnwrap(URLProtocolStub.lastRequest?.url)
        let encodedPath = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        XCTAssertTrue(encodedPath.hasSuffix("/The%20Artist/Song%20Title"), "Unexpected encoded path: \(encodedPath)")
    }

    /// `.urlPathAllowed` treats "/" as a legal path character and leaves it
    /// un-escaped, so an artist name containing one (e.g. "AC/DC") silently
    /// splits into extra path segments instead of being contained within the
    /// artist segment. Documents the current (likely unintended) behavior
    /// rather than asserting it's correct.
    func testArtistNameContainingSlashIsNotEscapedAndSplitsThePath() async throws {
        let json = #"{"lyrics":"text"}"#
        URLProtocolStub.requestHandler = { _ in (200, Data(json.utf8)) }
        let client = LyricsOvhClient(session: URLProtocolStub.makeSession())

        _ = try await client.fetchPlainLyrics(trackName: "Song", artistName: "AC/DC")

        let path = try XCTUnwrap(URLProtocolStub.lastRequest?.url?.path)
        XCTAssertEqual(path, "/v1/AC/DC/Song", "Unescaped slash produced an extra path segment: \(path)")
    }
}
