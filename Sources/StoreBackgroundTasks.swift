import BerthCore
import Foundation
import Observation

enum SubagentStopMode: Equatable {
    case subagent, turn
}

extension SubagentStopMode {
    var title: String { self == .subagent ? "Stop Subagent" : "Stop Turn" }
}

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
    var stoppedIDs: Set<String> = []
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
        let history = (source != nil && backgroundTaskModel.source == source ? backgroundTaskModel.tasks : []).map { task in
            guard task.status == .running, backgroundTaskModel.stoppedIDs.contains(task.id) else { return task }

            var stopped = task
            stopped.status = .stopped
            return stopped
        }
        let live = (conversationModels[tab.id]?.tasks ?? []).filter { task in
            !history.contains { $0.id == task.id || $0.toolUseID == task.id }
        }.map(SessionBackgroundTask.init)
        let terminals = tabs.compactMap { owned -> SessionBackgroundTask? in
            guard owned.parentTabID == tab.id, let title = owned.taskTitle else { return nil }

            return SessionBackgroundTask(id: owned.id.uuidString, kind: .terminal, title: title, started: owned.opened)
        }
        return history + live + terminals + finishedTerminalTasks[tab.id, default: []]
    }

    func canStop(_ task: SessionBackgroundTask) -> Bool {
        task.kind == .shell && task.status == .running && task.outputFile != nil && sessionTab?.sessionID.flatMap { liveBySession[$0] } != nil
    }

    func stopBackgroundTask(_ id: String) {
        let matches = backgroundTasks.filter { $0.id == id || $0.toolUseID == id }
        guard let task = matches.first(where: { $0.outputFile != nil }) ?? matches.first, canStop(task),
              let output = task.outputFile, let pid = sessionTab?.sessionID.flatMap({ liveBySession[$0]?.pid }) else { return }

        Task {
            let stopped = await Task.detached { await ProcessAncestry.stopShell(writing: output, under: pid) }.value
            if stopped { backgroundTaskModel.stoppedIDs.insert(task.id) }
        }
    }

    func backgroundTask(matching id: String) -> SessionBackgroundTask? {
        backgroundTasks.first { $0.id == id || $0.toolUseID == id }
    }

    func subagentStop(for task: SessionBackgroundTask) -> SubagentStopMode? {
        guard task.kind == .agent, task.status == .running, let sessionID = sessionTab?.sessionID, tab(forSession: sessionID) != nil,
              let live = liveBySession[sessionID], live.status != "waiting" else { return nil }

        let canDrive = SubagentStop.isSupported(version: live.version) && SubagentStop.keys(stopping: task, among: backgroundTasks) != nil
        if canDrive, live.status == "idle" { return .subagent }
        return live.status == "busy" && (task.runsInForeground || !canDrive) ? .turn : nil
    }

    func stopSubagent(_ task: SessionBackgroundTask) {
        switch subagentStop(for: task) {
        case .subagent:
            Task {
                if case let .refused(message) = await stopSubagentThroughTasksDialog(task) { subagentStopFailure = message }
            }

        case .turn:
            confirmingTurnStop = task

        case nil:
            break
        }
    }

    func stopTurn() {
        confirmingTurnStop = nil
        guard let sessionID = sessionTab?.sessionID, case let .refused(message) = interrupt(sessionID) else { return }

        subagentStopFailure = message
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
