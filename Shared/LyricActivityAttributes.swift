import ActivityKit
import Foundation

struct LyricActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackName: String
        var artistName: String
        var currentLine: String
        var nextLine: String
        /// True while audio is silent/paused; the widget freezes on the last line instead of blanking.
        var isPaused: Bool
    }

    var startedAt: Date
}
