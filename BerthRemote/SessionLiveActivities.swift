import ActivityKit
import Foundation
import os

private let log = Logger(subsystem: "dev.gustaf.berth.remote", category: "liveActivity")

final class SessionLiveActivities {
    private struct Tracked {
        let activity: Activity<SessionActivityAttributes>
        let startedAt: Date
        var last: LiveActivityState.Status
        var hasBeenActive = false
        var token: String?
    }

    private var tracked: [String: Tracked] = [:]
    private var observers: [String: [Task<Void, Never>]] = [:]
    private let send: (RemoteClientMessage) -> Void

    init(send: @escaping (RemoteClientMessage) -> Void) {
        self.send = send
    }

    func start(sessionID: String, title: String, state: LiveActivityState = .init(status: .working, since: Date.now.timeIntervalSince1970)) {
        guard tracked[sessionID] == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return log.info("not starting, activities are off or already tracked") }

        let existing = Activity<SessionActivityAttributes>.activities.first { $0.attributes.sessionID == sessionID }
        let activity: Activity<SessionActivityAttributes>
        do {
            activity = try existing ?? Activity.request(attributes: SessionActivityAttributes(sessionID: sessionID, title: title), content: .init(state: state, staleDate: nil), pushType: .token)
        } catch {
            return log.error("request failed \(error.localizedDescription, privacy: .public)")
        }

        log.info("started \(activity.id, privacy: .public)")
        tracked[sessionID] = Tracked(activity: activity, startedAt: .now, last: existing?.content.state.status ?? state.status)
        observers[sessionID] = [
            Task { [weak self] in
                for await token in activity.pushTokenUpdates { self?.register(token: token.map { String(format: "%02x", $0) }.joined(), for: sessionID) }
            },
            Task { [weak self] in
                for await activityState in activity.activityStateUpdates where activityState == .ended || activityState == .dismissed { self?.forget(sessionID) }
            },
        ]
    }

    func sync(groups: [RemoteGroup]) {
        let sessions = Dictionary(groups.flatMap(\.sessions).map { ($0.id, $0) }) { first, _ in first }
        for (sessionID, item) in tracked {
            let session = sessions[sessionID]
            let current = LiveActivityState(sessionStatus: session?.status, statusUpdatedAt: session?.waitingSince, turnStart: session?.turnStartedAt, now: .now)
            if current != nil { tracked[sessionID]?.hasBeenActive = true }
            switch LiveActivityStep.next(current: current, last: item.last, hasBeenActive: item.hasBeenActive || current != nil, age: Date.now.timeIntervalSince(item.startedAt)) {
            case .keep: continue

            case let .update(state):
                tracked[sessionID]?.last = state.status
                let id = item.activity.id
                Task { await Self.update(id: id, to: state) }

            case .end:
                forget(sessionID)
                let finished = LiveActivityState(status: .finished, since: Date.now.timeIntervalSince1970)
                let id = item.activity.id
                Task { await Self.end(id: id, with: finished) }
            }
        }
    }

    func resendTokens() {
        for (sessionID, item) in tracked {
            guard let token = item.token else { continue }

            send(.liveActivityToken(sessionID: sessionID, token: token, isSandbox: RemoteClient.isSandboxBuild))
        }
    }

    private nonisolated static func update(id: String, to state: LiveActivityState) async {
        await Activity<SessionActivityAttributes>.activities.first { $0.id == id }?.update(.init(state: state, staleDate: nil))
    }

    private nonisolated static func end(id: String, with state: LiveActivityState) async {
        await Activity<SessionActivityAttributes>.activities.first { $0.id == id }?.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + TimeInterval(LiveActivityState.dismissAfter)))
    }

    private func register(token: String, for sessionID: String) {
        tracked[sessionID]?.token = token
        send(.liveActivityToken(sessionID: sessionID, token: token, isSandbox: RemoteClient.isSandboxBuild))
    }

    private func forget(_ sessionID: String) {
        guard tracked.removeValue(forKey: sessionID) != nil else { return }

        observers.removeValue(forKey: sessionID)?.forEach { $0.cancel() }
        send(.liveActivityEnded(sessionID: sessionID))
    }
}

#if DEBUG
func runSnapshotLiveActivity() async {
    let defaults = UserDefaults.standard
    guard let title = defaults.string(forKey: "snapshotLiveActivity") else { return }

    let status = LiveActivityState.Status(rawValue: defaults.string(forKey: "snapshotLiveActivityStatus") ?? "") ?? .working
    let elapsed = defaults.double(forKey: "snapshotLiveActivityElapsed")
    let state = LiveActivityState(status: status, since: Date.now.timeIntervalSince1970 - elapsed)
    RemoteClient.shared.liveActivities.start(sessionID: "snapshot-live-activity", title: title, state: state)
    print("snapshotLiveActivity started \(Activity<SessionActivityAttributes>.activities.count)")
    let flip = defaults.double(forKey: "snapshotLiveActivityFlip")
    guard flip > 0 else { return }

    try? await Task.sleep(for: .seconds(flip))
    let waiting = LiveActivityState(status: .waiting, since: Date.now.timeIntervalSince1970)
    await Activity<SessionActivityAttributes>.activities.first?.update(.init(state: waiting, staleDate: nil))
}
#endif
