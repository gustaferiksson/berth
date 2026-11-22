import BerthCore
import Foundation
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

    mutating func attach(_ urls: [URL]) -> String {
        var tokens: [String] = []
        for url in urls where !files.contains(url) {
            files.append(url)
            guard Self.isImage(url) else { continue }

            numbers[url] = (numbers.values.max() ?? 0) + 1
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
    private(set) var tasks: [RemoteTask] = []
    private var reportedContext: RemoteContext?
    private(set) var isTurnOpen = false
    private(set) var lastChange = Date.now
    private(set) var queued: [String] = []
    @ObservationIgnored private var pending: [PendingPrompt] = []
    private(set) var hasLoaded = false
    private(set) var isSending = false
    private(set) var pickedModel: ModelChoice?
    private(set) var pickedEffort: EffortLevel?
    var openSubagent: Subagent?
    var notice: String?

    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var entries: [RemoteEntry] = []
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var end: Int?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var queuedByClaude: [String] = []
    @ObservationIgnored private var activity = TranscriptActivity()
    @ObservationIgnored private var agentLogs: [String: AgentLog] = [:]
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var needsRead = false
    @ObservationIgnored private var watcher: FileWatcher?

    init(tabID: Tab.ID, store: Store) {
        self.tabID = tabID
        self.store = store
    }

    var context: RemoteContext? {
        guard let tab = store.tabs.first(where: { $0.id == tabID }) else { return nil }
        guard !tab.agent.harness.supports(.backgroundTasks) else { return reportedContext }
        guard let sessionID = tab.sessionID, let summary = store.sessionsByID[sessionID], let context = summary.context else { return nil }

        return RemoteContext(model: CodexModels.displayName(for: context.model), tokens: context.tokens, window: context.window, date: summary.lastActivity, compactions: 0, lastCompaction: nil, effort: context.effort)
    }

    var entryCount: Int { entries.count }

    private var sessionID: String? { store.tabs.first { $0.id == tabID }?.sessionID }

    var blocksSending: Bool { isTurnOpen && !(store.liveBySession[sessionID ?? ""]?.reportsWaiting ?? false) }

    var draft: ConversationDraft {
        get { store.conversationDrafts[tabID] ?? ConversationDraft() }
        set { store.conversationDrafts[tabID] = newValue.text.isEmpty && newValue.files.isEmpty ? nil : newValue }
    }

    func attach(_ urls: [URL]) -> String {
        var draft = draft
        let tokens = draft.attach(urls)
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
        guard let sessionID, !sent.isEmpty, !isSending else { return }
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
        let outcome = await store.submit(sent.text, files: sent.orderedFiles, to: sessionID)
        guard case let .refused(message) = outcome else {
            if !text.isEmpty { show(pending: text) }
            return
        }

        notice = message
        if draft.isEmpty { draft = sent }
    }

    func show(pending text: String) {
        pending.append(PendingPrompt(text: text, sentAt: .now))
        reconcilePending()
        Task {
            try? await Task.sleep(for: .seconds(PendingPrompts.grace + 1))
            reconcilePending()
        }
    }

    private func reconcilePending() {
        pending = PendingPrompts.reconcile(pending, entries: entries, queued: queuedByClaude, now: .now)
        let shown = PendingPrompts.shown(pending, queued: queuedByClaude)
        if queued != shown { queued = shown }
    }

    func decline(waitingFor: String?, since: Double?) async {
        let sent = draft
        guard let sessionID, !sent.isEmpty, !isSending else { return }

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
        notice = "Claude is still waiting, so your message wasn’t sent"
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

    func openAgent(agentID: String?, toolUseID: String?) {
        guard let sessionID, let session = store.index.url(ofSession: sessionID) else { return }

        openSubagent = Subagent.locate(session: session, agentID: agentID, toolUseID: toolUseID)
    }

    func start() {
        guard let tab = store.tabs.first(where: { $0.id == tabID }) else { return }

        watcher = FileWatcher(paths: [store.sessionIndex(for: tab.agent).root.path], latency: 0.3) { [weak self] paths in
            guard let self else { return }

            if let sessionID, !paths.contains(where: { $0.contains(sessionID) }) { return }

            refresh()
        }
        refresh()
    }

    func stop() {
        watcher = nil
    }

    func refresh() {
        guard !isReading else {
            needsRead = true
            return
        }
        guard let tab = store.tabs.first(where: { $0.id == tabID }), let sessionID = tab.sessionID, let readTranscript = tab.agent.harness.readTranscript, let url = store.sessionIndex(for: tab.agent).url(ofSession: sessionID) else {
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
        let live = store.liveBySession[sessionID]
        let reportsActivity = tab.agent.harness.supports(.backgroundTasks)
        let catalogDirectory = Store.claudeDirectory.appending(path: "cache/model-catalog")
        Task {
            let (chunk, result) = await Task.detached {
                let chunk = readTranscript(url, after, queue)
                return (chunk, reportsActivity ? TranscriptActivity.report(url, previous: previous, logs: previousLogs, live: live, catalogDirectory: catalogDirectory) : nil)
            }.value
            isReading = false
            apply(chunk, result, url: url)
            if needsRead { refresh() }
        }
    }

    private func apply(_ chunk: TranscriptTail.Chunk?, _ result: (activity: TranscriptActivity, logs: [String: AgentLog], report: RemoteActivity)?, url: URL) {
        hasLoaded = true
        guard let chunk else { return }

        self.url = url
        end = chunk.end
        queue = chunk.queue
        if let result {
            activity = result.activity
            agentLogs = result.logs
            if tasks != result.report.tasks { tasks = result.report.tasks }
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
        queuedByClaude = chunk.queuedPrompts
        if !chunk.isContinuation || !chunk.entries.isEmpty {
            entries = (chunk.isContinuation ? entries : []) + chunk.entries
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
        if entries.count > previousCount || isTurnOpen != wasTurnOpen { lastChange = .now }
        reconcilePending()
    }
}
