import BerthCore
import Foundation
import Observation

enum SubagentStopMode: Equatable {
    case subagent, monitor, turn
}

extension SubagentStopMode {
    var title: String {
        if self == .subagent { return "Stop Subagent" }
        return self == .monitor ? "Stop Monitor" : "Stop Turn"
    }
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
            let claudePID = live.map(\.pid).flatMap { $0 > 1 ? $0 : nil }
            let (updated, tasks) = await Task.detached {
                var activity = previous
                activity.read(url)
                return (activity, activity.backgroundTasks(of: live, in: url, isProcessGone: { output in claudePID.map { ProcessAncestry.isOutputGone(output, under: $0) } ?? false }))
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
        guard let sessionID = sessionTab?.sessionID else { return false }

        return canStop(task, in: sessionID)
    }

    func canStop(_ task: SessionBackgroundTask, in sessionID: String) -> Bool {
        task.kind == .shell && task.status == .running && task.outputFile != nil && liveBySession[sessionID] != nil
    }

    func stopBackgroundTask(_ id: String) {
        let matches = backgroundTasks.filter { $0.id == id || $0.toolUseID == id }
        guard let task = matches.first(where: { $0.outputFile != nil }) ?? matches.first, let sessionID = sessionTab?.sessionID else { return }

        Task { await stopShell(task, in: sessionID) }
    }

    @discardableResult
    func stopShell(_ task: SessionBackgroundTask, in sessionID: String) async -> Bool {
        guard canStop(task, in: sessionID), let output = task.outputFile, let pid = liveBySession[sessionID]?.pid else { return false }

        let stopped = await Task.detached { await ProcessAncestry.stopShell(writing: output, under: pid) }.value
        if stopped { backgroundTaskModel.stoppedIDs.insert(task.id) }
        return stopped
    }

    func backgroundTasks(ofSession sessionID: String) async -> [SessionBackgroundTask] {
        if sessionTab?.sessionID == sessionID { return backgroundTasks }

        let agent = tab(forSession: sessionID)?.agent ?? sessionsByID[sessionID]?.agent ?? .claude
        guard let url = sessionIndex(for: agent).url(ofSession: sessionID) else { return [] }

        let live = liveBySession[sessionID]
        let claudePID = live?.pid
        return await Task.detached {
            var activity = TranscriptActivity(keepsTaskHistory: true)
            activity.read(url)
            return activity.backgroundTasks(of: live, in: url, isProcessGone: { output in claudePID.map { ProcessAncestry.isOutputGone(output, under: $0) } ?? false })
        }.value
    }

    func backgroundTask(matching id: String) -> SessionBackgroundTask? {
        backgroundTasks.first { $0.id == id || $0.toolUseID == id }
    }

    func subagentStop(for task: SessionBackgroundTask) -> SubagentStopMode? {
        guard let sessionID = sessionTab?.sessionID else { return nil }

        return subagentStop(for: task, in: sessionID, among: backgroundTasks)
    }

    func subagentStop(for task: SessionBackgroundTask, in sessionID: String, among tasks: [SessionBackgroundTask]) -> SubagentStopMode? {
        guard task.kind == .agent || task.kind == .monitor, task.status == .running, tab(forSession: sessionID) != nil,
              let live = liveBySession[sessionID], live.status != "waiting" else { return nil }

        let canDrive = SubagentStop.isSupported(version: live.version) && SubagentStop.keys(stopping: task, among: tasks) != nil
        if canDrive, live.status == "idle" { return task.kind == .monitor ? .monitor : .subagent }
        guard task.kind == .agent else { return nil }

        return live.status == "busy" && (task.runsInForeground || !canDrive) ? .turn : nil
    }

    func stopSubagent(_ task: SessionBackgroundTask) {
        switch subagentStop(for: task) {
        case .subagent, .monitor:
            guard let sessionID = sessionTab?.sessionID else { return }

            Task {
                let outcome = await stopSubagentThroughTasksDialog(task, in: sessionID, among: backgroundTasks) { [self] in backgroundTask(matching: task.id)?.status != .running }
                if case let .refused(message) = outcome { subagentStopFailure = message }
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
