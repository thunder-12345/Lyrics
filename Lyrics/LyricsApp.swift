import SwiftUI

@main
struct LyricsApp: App {
    @StateObject private var syncEngine = LyricsSyncEngine()
    private let keepAlive = SilentAudioKeepAlive()

    var body: some Scene {
        WindowGroup {
            ContentView(syncEngine: syncEngine, keepAlive: keepAlive)
        }
    }
}
