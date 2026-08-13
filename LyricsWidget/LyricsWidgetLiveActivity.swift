import ActivityKit
import SwiftUI
import WidgetKit

/// This is what surfaces on the CarPlay Dashboard — same Live Activity mechanism
/// Musixmatch's CarPlay lyrics feature uses. Keep lines short: this is meant to be
/// glanced at while driving, not read closely.
///
/// Note: a TimelineView-based self-updating approach was tried here (having
/// the widget compute the current line locally from a full timeline handed
/// over once per song) to avoid needing repeated Activity.update() calls,
/// but it doesn't actually work — WidgetKit renders a widget's view once and
/// doesn't keep re-invoking custom TimelineView content on the requested
/// schedule the way a live foreground app does. Text(timerInterval:) is the
/// only content that genuinely self-updates in a Live Activity without an
/// app-pushed update; arbitrary string content like lyric lines doesn't have
/// an equivalent. Back to plain state-driven rendering, pushed via
/// Activity.update() on every line change from LyricsSyncEngine.
struct LyricsWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        makeConfiguration()
    }

    private func makeConfiguration() -> some WidgetConfiguration {
        let configuration = ActivityConfiguration(for: LyricActivityAttributes.self) { context in
            if #available(iOS 18.0, *) {
                ActivityFamilyLyricsView(state: context.state)
            } else {
                LockScreenLyricsView(state: context.state)
            }
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.artistName)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.trackName)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isPaused ? "Paused" : context.state.currentLine)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
            } compactLeading: {
                // Fallback used by CarPlay when the small activity family
                // isn't available; keep it dense so lyrics don't dominate.
                Text(context.state.isPaused ? "Paused" : context.state.currentLine)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } compactTrailing: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "music.note")
                    .font(.caption2)
            } minimal: {
                Image(systemName: "music.note")
            }
        }

        if #available(iOS 18.0, *) {
            return configuration.supplementalActivityFamilies([.small])
        } else {
            return configuration
        }
    }
}

@available(iOS 18.0, *)
private struct ActivityFamilyLyricsView: View {
    let state: LyricActivityAttributes.ContentState
    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        if activityFamily == .small {
            SmallLyricsActivityView(state: state)
        } else {
            LockScreenLyricsView(state: state)
        }
    }
}

private struct SmallLyricsActivityView: View {
    let state: LyricActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.isPaused ? "Paused" : state.currentLine)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(3)
                .minimumScaleFactor(0.62)
                .multilineTextAlignment(.leading)
                .contentTransition(.identity)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !state.isPaused, !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .activityBackgroundTint(.black.opacity(0.6))
    }
}

private struct LockScreenLyricsView: View {
    let state: LyricActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(state.trackName) — \(state.artistName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(state.isPaused ? "Paused" : state.currentLine)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.75)

            if !state.isPaused {
                Text(state.nextLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
        .activityBackgroundTint(.black.opacity(0.6))
    }
}

#Preview(as: .content, using: LyricActivityAttributes(startedAt: .now)) {
    LyricsWidgetLiveActivity()
} contentStates: {
    LyricActivityAttributes.ContentState(
        trackName: "Example Song",
        artistName: "Example Artist",
        currentLine: "This is the current lyric line",
        nextLine: "This is the next lyric line",
        isPaused: false
    )
}
