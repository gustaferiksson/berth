import BerthCore
import Foundation
import GhosttyTerminal
import Observation

struct ConversationDraft {
    var text = ""
    var files: [URL] = []
    private(set) var numbers: [URL: Int] = [:]

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }

    var orderedFiles: [URL] {
        files.sorted { (text.range(of: token(for: $0))?.lowerBound ?? text.endIndex) < (text.range(of: token(for: $1))?.lowerBound ?? text.endIndex) }
    }

    static func isImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp"].contains(url.pathExtension.lowercased())
    }

    private func token(for url: URL) -> String {
        numbers[url].map { "[Image #\($0)]" } ?? "\0"
    }

    mutating func attach(_ urls: [URL], afterImage lastSent: Int) -> String {
        var tokens: [String] = []
        for url in urls where !files.contains(url) {
            files.append(url)
            guard Self.isImage(url) else { continue }

            numbers[url] = max(numbers.values.max() ?? 0, lastSent) + 1
            tokens.append(token(for: url))
        }
        return tokens.joined(separator: " ")
    }

    mutating func remove(_ url: URL) {
        let token = token(for: url)
        files.removeAll { $0 == url }
        numbers[url] = nil
        text = text.replacing(token, with: "")
    }

    mutating func prune() {
        for url in files where numbers[url] != nil && !text.contains(token(for: url)) {
            files.removeAll { $0 == url }
            numbers[url] = nil
        }
    }
}

@Observable
final class ConversationModel {
    let tabID: Tab.ID
    private(set) var turns: [Turn] = []
    @ObservationIgnored private(set) var details: [String: ToolCallDetails] = [:]
    @ObservationIgnored private var completedCalls: Set<String> = []
    private var transcriptTasks: [RemoteTask] = []
    private var shellTasks: [RemoteTask] = []
    private var rolloutApproval: (live: LiveSession, approval: PendingApproval)?
    private var reportedContext: RemoteContext?
    private(set) var isTurnOpen = false
    private(set) var permissionMode: String?
    private(set) var lastChange = Date.now
    private(set) var queued: [String] = []
    private(set) var pending: [PendingPrompt] = []
    private(set) var hasLoaded = false
    private(set) var isSending = false
    private(set) var pickedModel: ModelChoice?
    private(set) var pickedEffort: EffortLevel?
    var openSubagent: ConversationSubagentModel?
    var notice: String?

    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var entries: [RemoteEntry] = []
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var imageLines: [String: Range<Int>] = [:]
    @ObservationIgnored private var end: Int?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var activity = TranscriptActivity()
    @ObservationIgnored private var agentLogs: [String: AgentLog] = [:]
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var needsRead = false
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var shellPolling: Task<Void, Never>?

    init(tabID: Tab.ID, store: Store) {
        self.tabID = tabID
        self.store = store
    }

    var context: RemoteContext? {
        guard let tab = store.tabs.first(where: { $0.id == tabID }) else { return nil }
        guard !tab.agent.harness.usesTranscriptActivity else { return reportedContext }
        guard let sessionID = tab.sessionID, let summary = store.sessionsByID[sessionID] else { return nil }

        return tab.agent.harness.summaryContext?(summary)
    }

    var pullRequestWatch: PullRequestWatch? {
        sessionID.flatMap(store.pullRequestWatch(for:))
    }

    func stopWatching() async {
        guard let sessionID, !isSending else { return }

        isSending = true
        notice = nil
        defer { isSending = false }
        if case let .refused(message) = await store.stopWatching(sessionID) { notice = message }
    }

    var tasks: [RemoteTask] {
        guard !shellTasks.isEmpty, let sessionID, let live = store.liveBySession[sessionID], live.status == "idle", live.reportsWaiting else { return transcriptTasks }

        return transcriptTasks + shellTasks
    }

    func approval(for live: LiveSession?, harness: Harness) -> PendingApproval? {
        guard let live, live.status == "waiting" else { return nil }
        guard harness.readApproval != nil else { return PendingApproval.resolve(waitingFor: live.waitingFor, call: turns.last?.openCall) }

        return rolloutApproval?.live == live ? rolloutApproval?.approval : nil
    }

    var entryCount: Int { entries.count }

    #if DEBUG
    var isWatchingTranscript: Bool { watcher?.isRunning == true }
    #endif

    private var sessionID: String? { store.tabs.first { $0.id == tabID }?.sessionID }

    var blocksSending: Bool { isTurnOpen && !(store.liveBySession[sessionID ?? ""]?.reportsWaiting ?? false) }

    var draft: ConversationDraft {
        get { store.conversationDrafts[tabID] ?? ConversationDraft() }
        set { store.conversationDrafts[tabID] = newValue.text.isEmpty && newValue.files.isEmpty ? nil : newValue }
    }

    func attach(_ urls: [URL]) -> String {
        var draft = draft
        let lastSent = turns.lazy.compactMap { $0.prompt?.imageNumbers?.max() }.max() ?? 0
        let tokens = draft.attach(urls, afterImage: lastSent)
        self.draft = draft
        return tokens
    }

    func append(_ urls: [URL]) {
        let tokens = attach(urls)
        guard !tokens.isEmpty else { return }

        draft.text += (draft.text.isEmpty || draft.text.last?.isWhitespace == true ? "" : " ") + tokens + " "
    }

    func remove(_ url: URL) {
        var draft = draft
        draft.remove(url)
        self.draft = draft
    }

    func setText(_ text: String) {
        var draft = draft
        draft.text = text
        draft.prune()
        self.draft = draft
    }

    func send() async {
        let sent = draft
        guard let sessionID, !sent.isEmpty, !isSending, allowsSendingCommand(sent.text) else { return }
        guard !blocksSending else {
            let name = store.tabs.first { $0.id == tabID }?.agent.harness.name ?? "Agent"
            notice = "\(name) is working, so the message wasn’t sent. Stop it or wait for it to finish."
            return
        }

        isSending = true
        notice = nil
        draft = ConversationDraft()
        defer { isSending = false }

        let text = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAt = Date.now
        let outcome = await store.submit(sent.text, files: sent.orderedFiles, to: sessionID)
        guard case let .refused(message) = outcome else {
            if !text.isEmpty { show(pending: text, sentAt: sentAt) }
            return
        }

        notice = message
        if draft.isEmpty { draft = sent }
    }

    var canRecallQueued: Bool {
        !queued.isEmpty && draft.isEmpty && !isSending
    }

    func recallQueued() async {
        guard canRecallQueued, let sessionID else { return }

        let recalled = PendingPrompts.recall(queued, pending: pending)
        isSending = true
        defer { isSending = false }

        if case let .refused(message) = await store.recallQueued(recalled.text, in: sessionID) {
            notice = message
            return
        }

        pending = recalled.pending
        setText(draft.text.isEmpty ? recalled.text : recalled.text + "\n" + draft.text)
    }

    func show(pending text: String, sentAt: Date) {
        pending.append(PendingPrompt(text: text, sentAt: sentAt))
        reconcilePending()
        Task {
            try? await Task.sleep(for: .seconds(PendingPrompts.grace + 1))
            reconcilePending()
        }
    }

    private func reconcilePending() {
        let kept = PendingPrompts.reconcile(pending, entries: entries, queued: queued, now: .now)
        if pending != kept { pending = kept }
    }

    func decline(waitingFor: String?, since: Double?) async {
        let sent = draft
        guard let sessionID, !sent.isEmpty, !isSending, allowsSendingCommand(sent.text) else { return }

        isSending = true
        notice = nil
        defer { isSending = false }

        if case let .refused(message) = store.press(.escape, in: sessionID, answering: waitingFor, since: since) {
            notice = message
            return
        }

        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            store.refreshLive()
            guard store.liveBySession[sessionID]?.status != "waiting" else { continue }

            draft = ConversationDraft()
            if case let .refused(message) = await store.submit(sent.text, files: sent.orderedFiles, to: sessionID) {
                notice = message
                if draft.isEmpty { draft = sent }
            }
            return
        }
        let name = store.tab(forSession: sessionID)?.agent.harness.name ?? "Agent"
        notice = "\(name) is still waiting, so your message wasn’t sent"
    }

    private func allowsSendingCommand(_ text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.hasPrefix("/"), let tab = store.tabs.first(where: { $0.id == tabID }), tab.kind != .shell,
              let command = SlashCommand.builtIns(for: tab.agent.harness).first(where: { $0.requiresArguments && $0.name == name.lowercased() }) else { return true }

        notice = "\(command.name) needs an argument"
        return false
    }

    func choose(_ setting: RemoteSessionSetting) async {
        guard let sessionID, let context, !isSending else { return }

        let current: RemoteSessionSetting
        switch setting {
        case .model:
            current = .model(pickedModel ?? ModelChoice(modelID: context.model) ?? .default)

        case .effort:
            guard let effort = (pickedEffort?.rawValue ?? context.effort).flatMap(EffortLevel.init) else {
                notice = "Effort is unknown until Claude has replied"
                return
            }

            current = .effort(effort)
        }

        isSending = true
        notice = nil
        defer { isSending = false }

        if case let .refused(message) = await store.change(setting, from: current, in: sessionID) {
            notice = message
            return
        }

        switch setting {
        case let .model(choice): pickedModel = choice
        case let .effort(level): pickedEffort = level
        }
    }

    func interrupt() {
        guard let sessionID, case let .refused(message) = store.interrupt(sessionID) else { return }

        notice = message
    }

    func answer(_ key: RemoteKey, waitingFor: String?, since: Double?) {
        guard let sessionID, case let .refused(message) = store.press(key, in: sessionID, answering: waitingFor, since: since) else { return }

        notice = message
    }

    func promptImage(entryID: String, index: Int) async -> Data? {
        guard let url, let line = imageLines[TranscriptImages.promptImageID(entryID: entryID, index: index)] else { return nil }

        return await Task.detached { TranscriptImages.promptImage(entryID: entryID, index: index, in: url, line: line) }.value
    }

    func openAgent(agentID: String?, toolUseID: String?) {
        guard let tab = store.tabs.first(where: { $0.id == tabID }), let sessionID = tab.sessionID else { return }

        let index = store.sessionIndex(for: tab.agent)
        guard let session = index.url(ofSession: sessionID),
              let subagent = tab.agent.harness.locateSubagent(index.root, session, agentID, toolUseID)
        else { return }

        openSubagent = ConversationSubagentModel(subagent: subagent, root: index.root, session: session, harness: tab.agent.harness)
    }

    func start() {
        guard let tab = store.tabs.first(where: { $0.id == tabID }) else { return }

        lastChange = .now
        let harness = tab.agent.harness
        watcher = FileWatcher(paths: [store.sessionIndex(for: tab.agent).root.path], latency: 0.3) { [weak self] paths in
            guard let self else { return }

            if harness.readTasks == nil, let sessionID, !paths.contains(where: { $0.contains(sessionID) }) { return }

            refresh()
        }
        if harness.supports(.backgroundTasks), harness.readyTerminalProcess != nil {
            shellPolling = Task { [weak self] in
                while !Task.isCancelled, let self {
                    await refreshShellTasks()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        refresh()
    }

    func stop() {
        watcher = nil
        shellPolling?.cancel()
        shellPolling = nil
        needsRead = false
        openSubagent = nil
        notice = nil
        pending.removeAll()
        shellTasks.removeAll()
        pickedModel = nil
        pickedEffort = nil
        rolloutApproval = nil
    }

    private func refreshShellTasks() async {
        guard let tab = store.tabs.first(where: { $0.id == tabID }), let sessionID = tab.sessionID,
              let process = tab.agent.harness.readyTerminalProcess?(tab.terminal.title),
              let rollout = store.sessionIndex(for: tab.agent).url(ofSession: sessionID)
        else {
            if !shellTasks.isEmpty { shellTasks = [] }
            return
        }

        #if DEBUG
        if let tasks = store.fakeTerminalTasks[sessionID] {
            if tasks != shellTasks { shellTasks = tasks }
            return
        }
        #endif

        let socket = store.hostSocket(of: tabID)
        let isHosted = tab.isHosted
        let found = await Task.detached {
            let root: Int32
            if isHosted {
                guard let socket, let host = SessionHost.probe(socketPath: socket) else { return [RemoteTask]() }

                root = host.child
            } else {
                root = ProcessInfo.processInfo.processIdentifier
            }
            return ProcessAncestry.terminalTasks(for: rollout, under: root, named: process.name, excluding: process.excludedChildren)
        }.value
        guard !Task.isCancelled, let current = store.tab(forSession: sessionID), current.id == tabID else { return }

        let tasks = current.agent.harness.readyTerminalProcess?(current.terminal.title) == nil ? [] : found
        if tasks != shellTasks { shellTasks = tasks }
    }

    func refresh() {
        guard !isReading else {
            needsRead = true
            return
        }
        guard let tab = store.tabs.first(where: { $0.id == tabID }), let sessionID = tab.sessionID else {
            hasLoaded = true
            return
        }

        let harness = tab.agent.harness
        let live = store.liveBySession[sessionID]
        let index = store.sessionIndex(for: tab.agent)
        guard let readTranscript = harness.readTranscript, let url = index.url(ofSession: sessionID) else {
            if harness.readApproval != nil, let live, live.status == "waiting" { rolloutApproval = (live, .loading) }
            hasLoaded = true
            return
        }

        isReading = true
        needsRead = false
        let isSameFile = url == self.url
        let after = isSameFile ? end : nil
        let queue = queue
        let previous = isSameFile ? activity : TranscriptActivity()
        let previousLogs = isSameFile ? agentLogs : [:]
        let root = index.root
        let catalogDirectory = Store.claudeDirectory.appending(path: "cache/model-catalog")
        Task {
            let (chunk, result, tasks, approval) = await Task.detached {
                let chunk = readTranscript(url, after, queue)
                let result = harness.usesTranscriptActivity ? TranscriptActivity.report(url, previous: previous, logs: previousLogs, live: live, catalogDirectory: catalogDirectory) : nil
                let tasks = harness.supports(.backgroundTasks) ? harness.readTasks?(root, url) : nil
                let approval = live?.status == "waiting" ? harness.readApproval?(url) : nil
                return (chunk, result, tasks, approval)
            }.value
            isReading = false
            if self.sessionID == sessionID {
                if harness.readApproval != nil, live == store.liveBySession[sessionID] {
                    let updated: PendingApproval = approval ?? .loading
                    if let live, live.status == "waiting" {
                        if rolloutApproval?.live != live || rolloutApproval?.approval != updated { rolloutApproval = (live, updated) }
                    } else if rolloutApproval != nil {
                        rolloutApproval = nil
                    }
                }
                if let tasks, transcriptTasks != tasks { transcriptTasks = tasks }
                apply(chunk, result, url: url)
            }
            if needsRead { refresh() }
        }
    }

    private func apply(_ chunk: TranscriptTail.Chunk?, _ result: (activity: TranscriptActivity, logs: [String: AgentLog], report: RemoteActivity)?, url: URL) {
        hasLoaded = true
        guard let chunk else { return }

        self.url = url
        imageLines = (chunk.isContinuation ? imageLines : [:]).merging(chunk.imageLines) { $1 }
        end = chunk.end
        queue = chunk.queue
        if let result {
            activity = result.activity
            if permissionMode != result.activity.permissionMode { permissionMode = result.activity.permissionMode }
            agentLogs = result.logs
            if transcriptTasks != result.report.tasks { transcriptTasks = result.report.tasks }
            if reportedContext != result.report.context {
                if reportedContext?.model != result.report.context?.model || reportedContext?.date != result.report.context?.date { pickedModel = nil }
                if reportedContext?.effort != result.report.context?.effort { pickedEffort = nil }
                reportedContext = result.report.context
            }
        }
        let previousCount = entries.count
        let wasTurnOpen = isTurnOpen
        if let open = chunk.isTurnOpen {
            let newest = chunk.entries.compactMap(\.date).max() ?? .distantPast
            isTurnOpen = open && (chunk.isContinuation || newest > Date.now.addingTimeInterval(-3600))
        }
        if queued != chunk.queuedPrompts { queued = chunk.queuedPrompts }
        if !chunk.isContinuation || !chunk.entries.isEmpty {
            if !chunk.isContinuation {
                entries.removeAll()
                details.removeAll()
                completedCalls.removeAll()
            }
            entries.append(contentsOf: chunk.entries)
            if chunk.isContinuation, let continued = Turn.continuing(turns, with: chunk.entries) {
                turns = continued
            } else {
                rebuildTurns()
            }
        }
        if entries.count > previousCount || isTurnOpen != wasTurnOpen { lastChange = .now }
        reconcilePending()
    }

    private func rebuildTurns() {
        turns = Turn.turns(from: entries)
        var currentDetails: [String: ToolCallDetails] = [:]
        var currentCompleted: Set<String> = []
        for turn in turns {
            for part in turn.parts {
                let calls: [ToolCall] = switch part {
                case let .work(calls), let .cards(calls): calls
                case .reply: []
                }
                for call in calls {
                    currentDetails[call.id] = if let cached = details[call.id], call.result == nil || completedCalls.contains(call.id) { cached } else { call.details }
                    if call.result != nil { currentCompleted.insert(call.id) }
                }
            }
        }
        details = currentDetails
        completedCalls = currentCompleted
    }
}
