import XCTest
@testable import Lyrics

final class TrackMatchTests: XCTestCase {
    func testCurrentPlaybackPositionExtrapolatesFromElapsedAndTimeSinceMatch() {
        let matchedAt = Date(timeIntervalSince1970: 1_000)
        let match = TrackMatch(trackName: "Song", artistName: "Artist", elapsedSeconds: 30, matchedAt: matchedAt, durationSeconds: nil)

        let position = match.currentPlaybackPosition(now: matchedAt.addingTimeInterval(5))

        XCTAssertEqual(position, 35, accuracy: 0.0001)
    }

    func testRemainingSecondsIsNilWhenDurationUnknown() {
        let match = TrackMatch(trackName: "Song", artistName: "Artist", elapsedSeconds: 30, matchedAt: Date(), durationSeconds: nil)
        XCTAssertNil(match.remainingSeconds())
    }

    func testRemainingSecondsCountsDownFromDuration() {
        let matchedAt = Date(timeIntervalSince1970: 1_000)
        let match = TrackMatch(trackName: "Song", artistName: "Artist", elapsedSeconds: 170, matchedAt: matchedAt, durationSeconds: 180)

        let remaining = match.remainingSeconds(now: matchedAt.addingTimeInterval(5))

        XCTAssertEqual(remaining!, 5, accuracy: 0.0001)
    }

    func testDecodesFromTheGistJsonShapeWrittenByTheMacRelay() throws {
        let json = """
        {"track":"Song","artist":"Artist","elapsedSeconds":12.5,"updatedAt":"2026-08-12T00:00:00Z","duration":200.0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let match = try decoder.decode(TrackMatch.self, from: Data(json.utf8))

        XCTAssertEqual(match.trackName, "Song")
        XCTAssertEqual(match.artistName, "Artist")
        XCTAssertEqual(match.elapsedSeconds, 12.5)
        XCTAssertEqual(match.durationSeconds, 200.0)
    }

    func testDecodesWithMissingDurationAsNil() throws {
        let json = """
        {"track":"Song","artist":"Artist","elapsedSeconds":0,"updatedAt":"2026-08-12T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let match = try decoder.decode(TrackMatch.self, from: Data(json.utf8))

        XCTAssertNil(match.durationSeconds)
    }
}
