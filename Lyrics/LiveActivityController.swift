import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    private var activity: Activity<LyricActivityAttributes>?

    func start(trackName: String, artistName: String) {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("Live Activities are disabled in Settings — nothing will show on CarPlay.")
            TimingLogger.log("live_activity_disabled")
            return
        }

        let startedAt = Date()
        let attributes = LyricActivityAttributes(startedAt: Date())
        let state = LyricActivityAttributes.ContentState(
            trackName: trackName,
            artistName: artistName,
            currentLine: "",
            nextLine: "",
            isPaused: false
        )

        do {
            activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            TimingLogger.log("live_activity_started ms=\(TimingLogger.elapsedMS(since: startedAt)) track=\"\(trackName)\"")
        } catch {
            print("Failed to start Live Activity: \(error)")
            TimingLogger.log("live_activity_start_failed ms=\(TimingLogger.elapsedMS(since: startedAt)) error=\"\(error.localizedDescription)\"")
        }
    }

    func update(trackName: String, artistName: String, currentLine: String, nextLine: String, isPaused: Bool) async {
        guard let activity else { return }
        let startedAt = Date()
        let state = LyricActivityAttributes.ContentState(
            trackName: trackName,
            artistName: artistName,
            currentLine: currentLine,
            nextLine: nextLine,
            isPaused: isPaused
        )
        await activity.update(.init(state: state, staleDate: nil))
        TimingLogger.log("live_activity_updated ms=\(TimingLogger.elapsedMS(since: startedAt)) paused=\(isPaused)")
    }

    func end() async {
        TimingLogger.log("live_activity_end_requested")
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
    }
}
