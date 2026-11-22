import BerthCore
import Foundation
import Observation

@Observable
final class ConversationModel {
    let tabID: Tab.ID
    private(set) var turns: [Turn] = []
    private(set) var tasks: [RemoteTask] = []
    private(set) var context: RemoteContext?
    private(set) var queued: [String] = []
    private(set) var hasLoaded = false

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
        guard let sessionID = store.tabs.first(where: { $0.id == tabID })?.sessionID, let url = store.index.url(ofSession: sessionID) else {
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
                let chunk = TranscriptTail.read(url, after: after, queue: queue)
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
        if context != result.report.context { context = result.report.context }
        if queued != chunk.queuedPrompts { queued = chunk.queuedPrompts }
        guard !chunk.isContinuation || !chunk.entries.isEmpty else { return }

        entries = (chunk.isContinuation ? entries : []) + chunk.entries
        turns = Turn.turns(from: entries)
    }
}
