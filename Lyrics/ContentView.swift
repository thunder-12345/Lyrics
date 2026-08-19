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
                Text(syncEngine.currentLine)
                    .font(.title3)
                Text(syncEngine.nextLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            keepAlive.start()
            syncEngine.start(keepAlive: keepAlive)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

#Preview {
    ContentView(syncEngine: LyricsSyncEngine(), keepAlive: SilentAudioKeepAlive())
}
