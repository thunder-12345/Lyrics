import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var syncEngine: LyricsSyncEngine
    let keepAlive: SilentAudioKeepAlive

    var body: some View {
        VStack(spacing: 24) {
            Text("Lyrics")
                .font(.largeTitle.bold())

            Text("Keep this screen open while you drive — the CarPlay display only stays live while the app is in the foreground (iOS limits background Live Activity updates to ~60s). The screen won't auto-lock while this is open.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Divider()

            Picker("Display", selection: $syncEngine.displayMode) {
                ForEach(LyricsDisplayMode.allCases) { mode in
                    Text(mode.label)
                        .tag(mode)
                        .disabled(mode != .original && syncEngine.isEnglishDetected)
                }
            }
            .pickerStyle(.segmented)

            if (syncEngine.displayMode == .translated || syncEngine.displayMode == .combined) && syncEngine.isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Translating…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(syncEngine.statusText)
                    .font(.headline)

                if let split = splitCombinedLine(syncEngine.currentLine) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(split.top)
                        Divider()
                        Text(split.bottom)
                    }
                    .font(.body)
                } else {
                    Text(syncEngine.currentLine)
                        .font(.title3)
                }

                Text(syncEngine.nextLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .onAppear {
            // The unit test target hosts inside this app (required for
            // `@testable import` of an application target) and launches it
            // like a normal run, so without this guard every test run would
            // start real background polling: live GitHub/Gemini network
            // calls and writes to the real on-disk localization cache.
            guard !isRunningUnderTests else { return }
            UIApplication.shared.isIdleTimerDisabled = true
            keepAlive.start()
            syncEngine.start(keepAlive: keepAlive)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

private let isRunningUnderTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

/// Combined mode packs two lines (transliterated + translated) into
/// currentLine as "top\nbottom" -- splitting it here renders each half as
/// its own Text with a divider between them.
private func splitCombinedLine(_ text: String) -> (top: String, bottom: String)? {
    let parts = text.components(separatedBy: "\n")
    guard parts.count == 2 else { return nil }
    return (parts[0], parts[1])
}

#Preview {
    ContentView(syncEngine: LyricsSyncEngine(), keepAlive: SilentAudioKeepAlive())
}
