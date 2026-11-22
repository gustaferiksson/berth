import BerthCore
import Foundation
import Observation

struct ConversationDraft {
    var text = ""
    var files: [URL] = []

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }
}

@Observable
final class ConversationModel {
    let tabID: Tab.ID
    private(set) var turns: [Turn] = []
    private(set) var tasks: [RemoteTask] = []
    private(set) var context: RemoteContext?
    private(set) var queued: [String] = []
    private(set) var hasLoaded = false
    private(set) var isSending = false
    private(set) var pickedModel: ModelChoice?
    private(set) var pickedEffort: EffortLevel?
    var notice: String?

    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var entries: [RemoteEntry] = []
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var end: Int?
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var activity = TranscriptActivity()
    @ObservationIgnored private var agentLogs: [String: AgentLog] = [:]
    @ObservationIgnored private var isReading = false
    @ObservationIgnored private var needsRead = false
    @ObservationIgnored private var watcher: FileWatcher?

    init(tabID: Tab.ID, store: Store) {
        self.tabID = tabID
        self.store = store
    }

    var entryCount: Int { entries.count }

    private var sessionID: String? { store.tabs.first { $0.id == tabID }?.sessionID }

    var draft: ConversationDraft {
        get { store.conversationDrafts[tabID] ?? ConversationDraft() }
        set { store.conversationDrafts[tabID] = newValue.text.isEmpty && newValue.files.isEmpty ? nil : newValue }
    }

    func send() async {
        let sent = draft
        guard let sessionID, !sent.isEmpty, !isSending else { return }

        isSending = true
        notice = nil
        draft = ConversationDraft()
        defer { isSending = false }

        guard case let .refused(message) = await store.submit(sent.text, files: sent.files, to: sessionID) else { return }

        notice = message
        if draft.isEmpty { draft = sent }
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
            if case let .refused(message) = await store.submit(sent.text, files: sent.files, to: sessionID) {
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

    func start() {
        watcher = FileWatcher(paths: [Store.claudeDirectory.appending(path: "projects").path], latency: 0.3) { [weak self] _ in self?.refresh() }
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
        guard let tab = store.tabs.first(where: { $0.id == tabID }), let sessionID = tab.sessionID, let readTranscript = tab.agent.harness.readTranscript, let url = store.index.url(ofSession: sessionID) else {
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
        let catalogDirectory = Store.claudeDirectory.appending(path: "cache/model-catalog")
        Task {
            let (chunk, result) = await Task.detached {
                let chunk = readTranscript(url, after, queue)
                return (chunk, TranscriptActivity.report(url, previous: previous, logs: previousLogs, live: live, catalogDirectory: catalogDirectory))
            }.value
            isReading = false
            apply(chunk, result, url: url)
            if needsRead { refresh() }
        }
    }

    private func apply(_ chunk: TranscriptTail.Chunk?, _ result: (activity: TranscriptActivity, logs: [String: AgentLog], report: RemoteActivity), url: URL) {
        hasLoaded = true
        guard let chunk else { return }

        self.url = url
        end = chunk.end
        queue = chunk.queue
        activity = result.activity
        agentLogs = result.logs
        if tasks != result.report.tasks { tasks = result.report.tasks }
        if context != result.report.context {
            if context?.model != result.report.context?.model || context?.date != result.report.context?.date { pickedModel = nil }
            if context?.effort != result.report.context?.effort { pickedEffort = nil }
            context = result.report.context
        }
        if queued != chunk.queuedPrompts { queued = chunk.queuedPrompts }
        guard !chunk.isContinuation || !chunk.entries.isEmpty else { return }

        entries = (chunk.isContinuation ? entries : []) + chunk.entries
        turns = Turn.turns(from: entries)
    }
}
