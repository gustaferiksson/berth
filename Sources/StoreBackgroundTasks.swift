import BerthCore
import Foundation
import Observation

struct BackgroundTaskSource: Hashable, Sendable {
    let tabID: Tab.ID
    let sessionID: String
    let root: URL
    let transcript: URL
    let agent: Agent
}

@Observable
final class BackgroundTaskModel {
    private(set) var source: BackgroundTaskSource?
    private(set) var tasks: [SessionBackgroundTask] = []
    @ObservationIgnored private var activity = TranscriptActivity(keepsTaskHistory: true)

    func observe(_ source: BackgroundTaskSource, store: Store) async {
        if self.source != source {
            self.source = source
            tasks = []
            activity = TranscriptActivity(keepsTaskHistory: true)
        }
        while !Task.isCancelled {
            let previous = activity
            let live = store.liveBySession[source.sessionID]
            let url = source.transcript
            let (updated, tasks) = await Task.detached {
                var activity = previous
                activity.read(url)
                return (activity, activity.backgroundTasks(of: live, in: url))
            }.value
            guard !Task.isCancelled else { return }

            activity = updated
            if self.tasks != tasks { self.tasks = tasks }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

extension Store {
    var backgroundTaskSource: BackgroundTaskSource? {
        guard !isHarborShown, let tab = sessionTab, let sessionID = tab.sessionID else { return nil }

        #if DEBUG
        if let fixture = backgroundTaskFixture, fixture.tabID == tab.id { return fixture }
        #endif

        let index = sessionIndex(for: tab.agent)
        guard let transcript = index.url(ofSession: sessionID) else { return nil }

        return BackgroundTaskSource(tabID: tab.id, sessionID: sessionID, root: index.root, transcript: transcript, agent: tab.agent)
    }

    var backgroundTasks: [SessionBackgroundTask] {
        guard let tab = sessionTab else { return [] }

        let source = backgroundTaskSource
        let history = source != nil && backgroundTaskModel.source == source ? backgroundTaskModel.tasks : []
        let live = (conversationModels[tab.id]?.tasks ?? []).filter { task in
            !history.contains { $0.id == task.id || $0.toolUseID == task.id }
        }.map(SessionBackgroundTask.init)
        let terminals = tabs.compactMap { owned -> SessionBackgroundTask? in
            guard owned.parentTabID == tab.id, let title = owned.taskTitle else { return nil }

            return SessionBackgroundTask(id: owned.id.uuidString, kind: .terminal, title: title, started: owned.opened)
        }
        return history + live + terminals + finishedTerminalTasks[tab.id, default: []]
    }

    var canShowTasksPane: Bool {
        sessionPane == .tasks || !backgroundTasks.isEmpty
    }

    func selectedBackgroundTask(in tasks: [SessionBackgroundTask]) -> SessionBackgroundTask? {
        let selected = sessionTab.flatMap { selectedBackgroundTaskIDs[$0.id] }
        if let selected, let task = tasks.first(where: { selected == $0.id || selected == $0.toolUseID }) { return task }

        let groups = BackgroundTaskGroups(tasks)
        return groups.running.first ?? groups.finished.first
    }

    func showTasksPane(selecting taskID: String? = nil) {
        guard let session = sessionTab, taskID != nil || canShowTasksPane else { return }

        let selected = taskID ?? selectedBackgroundTask(in: backgroundTasks)?.id
        launcherMode = nil
        isHarborShown = false
        leaveTerminalPane(of: session)
        selectedBackgroundTaskIDs[session.id] = selected
        sessionPanes[session.id] = .tasks
    }
}
