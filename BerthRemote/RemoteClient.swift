import CryptoKit
import Foundation
import Observation
import Security
import UIKit

@Observable
final class RemoteClient {
    enum UploadState: Equatable {
        case uploading
        case done
        case failed(String)
    }

    enum PullRequestLoad: Equatable {
        case loaded(RemotePullRequestDetail)
        case failed
    }

    enum ChangesLoad: Equatable {
        case loaded(RemoteChanges)
        case failed
    }

    enum DiffLoad: Equatable {
        case loaded(RemoteFileDiff)
        case failed
    }

    enum ImageLoad: Equatable {
        case loading
        case loaded(Data)
        case failed
    }

    struct ImageKey: Hashable {
        let id: String
        let variant: RemoteImageVariant
    }

    struct ChangeKey: Hashable {
        let sessionID: String
        let path: String
        let isCommitted: Bool
    }

    enum State: Equatable {
        case disconnected(String?)
        case connecting
        case connected
        case reconnecting
    }

    private static let tokenQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.gustaf.berth.remote", kSecAttrAccount as String: "token"]

    static var savedToken: String? {
        var result: CFTypeRef?
        guard SecItemCopyMatching(tokenQuery.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }

        return String(decoding: data, as: UTF8.self)
    }

    private(set) var state = State.disconnected(nil) {
        didSet {
            guard state != .connected else { return }

            activity = [:]
            pullRequests = [:]
            changes = [:]
            diffs = [:]
            taskDetails = [:]
            slashCommands = [:]
            requestedSlashCommands = []
            images = images.filter { if case .loaded = $0.value { true } else { false } }
            for (id, upload) in uploads where upload == .uploading { uploads[id] = .failed("The connection dropped") }
        }
    }

    private(set) var groups: [RemoteGroup] = []
    private(set) var folders: [String] = []
    private(set) var entries: [String: [RemoteEntry]] = [:]
    private(set) var queued: [String: [String]] = [:]
    private(set) var pending: [String: [PendingPrompt]] = [:]
    @ObservationIgnored private(set) var pendingAttachments: [String: [Date: [Attachment]]] = [:]
    private(set) var activity: [String: RemoteActivity] = [:]
    private(set) var pullRequests: [String: PullRequestLoad] = [:]
    private(set) var changes: [String: ChangesLoad] = [:]
    private(set) var diffs: [ChangeKey: DiffLoad] = [:]
    private(set) var taskDetails: [String: RemoteTaskDetail] = [:]
    private(set) var features: [String] = []
    private(set) var slashCommands: [String: [SlashCommand]] = [:]
    private(set) var usage: PlanUsage?
    private(set) var codexUsage: CodexUsage?
    private(set) var images: [ImageKey: ImageLoad] = [:]
    private(set) var transcriptSearch: (query: String, hits: [RemoteSearchHit], isIndexing: Bool)?
    var searchJump: (sessionID: String, snippet: RemoteSnippet)?
    private(set) var uploads: [String: UploadState] = [:]
    var draftTexts: [String: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:] {
        didSet {
            #if DEBUG
            if Self.isDemo { return }
            #endif
            UserDefaults.standard.set(draftTexts.filter { !$0.value.isEmpty }, forKey: "drafts")
        }
    }

    var draftAttachments: [String: [Attachment]] = [:]
    var notice: String?
    var openedSessionID: String?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var sessionsReceived = 0
    @ObservationIgnored private var subscribedSessionID: String?
    @ObservationIgnored private var requestedSlashCommands: Set<String> = []
    @ObservationIgnored private var lastSent: (sessionID: String, date: Date)?

    init() {
        if let legacy = UserDefaults.standard.string(forKey: "remoteToken"), legacy.isEmpty || Self.save(token: legacy) {
            UserDefaults.standard.removeObject(forKey: "remoteToken")
        }
        if UserDefaults.standard.string(forKey: "remoteURL").flatMap(Self.url(from:)) != nil, Self.savedToken != nil { state = .reconnecting }
    }

    static func url(from address: String) -> URL? {
        guard let url = URL(string: address), url.host()?.isEmpty == false else { return nil }

        #if DEBUG
        if url.scheme == "ws", url.host() == "127.0.0.1" || url.host() == "localhost" { return url }
        #endif
        return url.scheme == "wss" ? url : nil
    }

    func connect(to url: URL, token: String) {
        guard Self.save(token: token) else {
            state = .disconnected("Couldn’t save the token in the Keychain.")
            return
        }

        UserDefaults.standard.set(url.absoluteString, forKey: "remoteURL")
        state = .connecting
        open(url, token: token)
    }

    func resume() {
        guard state == .reconnecting, task == nil, let url = UserDefaults.standard.string(forKey: "remoteURL").flatMap(Self.url(from:)), let token = Self.savedToken else { return }

        open(url, token: token)
    }

    #if DEBUG
    private static let demoSectionsFile = UserDefaults.standard.string(forKey: "snapshotDemoSectionsFile")
    static let isDemo = UserDefaults.standard.bool(forKey: "snapshotDemo") || demoSectionsFile != nil
    static let showsDemoList = UserDefaults.standard.bool(forKey: "snapshotDemoList") || demoSectionsFile != nil

    func seedDemo() {
        state = .connected
        features = [RemoteTriageFeature.name]
        if let file = Self.demoSectionsFile {
            do {
                groups = try JSONDecoder().decode([RemoteGroup].self, from: Data(contentsOf: URL(filePath: file)))
            } catch {
                print("Could not load demo sections from \(file): \(error)")
            }
            return
        }

        let now = Date.now
        let session = RemoteSession(id: "demo", title: "Refine the activity feed", folder: "/Projects/fieldnotes", branch: "main", lastActivity: now, status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, agent: .legacyClaude)
        groups = Self.showsDemoList ? demoListGroups(session: session, now: now) : [RemoteGroup(id: "recent:active", title: "Active", sessions: [session])]
        entries[session.id] = [
            RemoteEntry(id: "prompt-1", kind: .prompt, text: "Find out why the activity feed jumps when a new entry arrives."),
            RemoteEntry(id: "reply-1", kind: .reply, text: "The feed rebuilds every row when a new entry arrives. Because the rows use their positions as identifiers, inserting at the top changes the identity of every visible row."),
            RemoteEntry(id: "prompt-2", kind: .prompt, text: "Use the entry IDs and preserve the reader’s position."),
            RemoteEntry(id: "reply-2", kind: .reply, text: "The feed now identifies rows by entry ID. When someone is reading older entries, it keeps the first visible row in place. At the top of the feed, new entries still appear automatically."),
            RemoteEntry(id: "prompt-3", kind: .prompt, text: "What should I verify before shipping?"),
            RemoteEntry(id: "reply-3", kind: .reply, text: """
            Start at the top of the activity feed and wait for a new entry. It should appear above the existing entries without a visible jump. Scroll down a few screens and repeat the check. The entry you were reading should stay in place, even when several updates arrive together.

            Then open a detail view and return to the feed. Check that you land on the same entry you left, including when the feed refreshed in the background. Try this once more with larger text, where a single entry can span most of the screen.

            Finally, reload the feed from an empty state and confirm that the first page appears at the top. If the entry you were reading has been deleted, the feed should restore the nearest remaining entry.
            """),
        ]
        if UserDefaults.standard.bool(forKey: "snapshotDemoCode") {
            let path = String(repeating: "/Users/x/Repos/berth/git/refs/heads/browser-read-access", count: 3)
            let command = "cd /tmp && for i in 408 409 410 412 325; do gh issue close $i -R gustaferiksson/berth -r completed; done; gh pr close 381 -R gustaferiksson/berth; gh pr close 382 -R gustaferiksson/berth; gh api -X DELETE repos/gustaferiksson/berth/git/refs/heads/browser-read-access"
            let output = [408, 409, 410, 412, 325].map { "Closed issue #\($0)" } + [381, 382].map { "Closed pull request #\($0)" }
            entries[session.id]?.append(contentsOf: [
                RemoteEntry(id: "reply-code", kind: .reply, text: "```\n\(path)\n```"),
                RemoteEntry(id: "prompt-shell", kind: .prompt, text: command, name: "bash", command: command),
                RemoteEntry(id: "output-shell", kind: .toolResult, text: output.prefix(3).joined(separator: "\n"), name: "bash-output"),
                RemoteEntry(id: "prompt-shell-long", kind: .prompt, text: command, name: "bash", command: command),
                RemoteEntry(id: "output-shell-long", kind: .toolResult, text: output.joined(separator: "\n"), name: "bash-output"),
            ])
        }
        if UserDefaults.standard.bool(forKey: "snapshotDemoImageOnly") {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160)).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            }
            entries[session.id]?.append(RemoteEntry(id: "prompt-image", kind: .prompt, text: "[Image #1]", images: [image], imageNumbers: [1]))
        }
        activity[session.id] = RemoteActivity(tasks: [], context: RemoteContext(model: "claude-opus-5-5", tokens: 48_000, window: 200_000, date: .now, compactions: 0, lastCompaction: nil, effort: "medium"))
        let resets = Date.now.addingTimeInterval(3 * 3600)
        usage = PlanUsage(windows: [
            UsageWindow(id: "five_hour", title: "Session", length: 5 * 3600, used: 0.42, resetsAt: resets),
            UsageWindow(id: "seven_day", title: "Week", length: 7 * 86_400, used: 0.81, resetsAt: resets.addingTimeInterval(3 * 86_400)),
        ])
        codexUsage = CodexUsage(usage: PlanUsage(windows: [
            UsageWindow(id: "five_hour", title: "Session", length: 5 * 3600, used: 0.18, resetsAt: resets),
            UsageWindow(id: "seven_day", title: "Week", length: 7 * 86_400, used: 0.47, resetsAt: resets.addingTimeInterval(3 * 86_400)),
        ]), recordedAt: .now.addingTimeInterval(-2 * 3600))
        if UserDefaults.standard.bool(forKey: "snapshotDemoSlashCommands") {
            slashCommands[session.id] = SlashCommand.claudeBuiltIns + [
                SlashCommand(RemoteSlashCommand(name: "/compare", summary: "Compare two revisions", source: "project", requiresArguments: false, argumentHint: "<revision>")),
                SlashCommand(RemoteSlashCommand(name: "/coverage", summary: "Generate a coverage report", source: "user", requiresArguments: false, argumentHint: nil)),
            ]
            draftTexts[session.id] = "/co"
        }
        if !Self.showsDemoList { openedSessionID = session.id }
    }

    private func demoListGroups(session: RemoteSession, now: Date) -> [RemoteGroup] {
        guard let pullRequests = URL(string: "https://example.invalid") else { return [] }

        let fieldnotes = session.folder
        let harborLog = "/Projects/harbor-log"
        let tidewater = "/Projects/tidewater"
        let atlasAPI = "/Projects/atlas-api"
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-12 * 3600)
        let waitingSince = now.addingTimeInterval(-46)
        let attention = [
            RemoteSession(id: "demo-waiting", title: "Repair the import checks", folder: fieldnotes, branch: "fix/import-checks", lastActivity: waitingSince, status: "waiting", waitingFor: "permission", waitingSince: waitingSince.timeIntervalSince1970, isOpen: true, isLocked: false, pullRequest: RemotePullRequest(number: 142, state: "Open", url: pullRequests.appending(path: "fieldnotes/pull/142"), checks: "failed")),
        ]
        let working = [
            RemoteSession(id: "demo-busy-index", title: "Rebuild the index", folder: atlasAPI, branch: "fix/rebuild-index", lastActivity: now.addingTimeInterval(-4), status: "busy", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, turnStartedAt: now.addingTimeInterval(-4)),
            RemoteSession(id: "demo-busy-charts", title: "Update the tide charts", folder: tidewater, branch: "feature/tide-charts", lastActivity: now.addingTimeInterval(-3 * 60), status: "busy", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, pullRequest: RemotePullRequest(number: 93, state: "Open", url: pullRequests.appending(path: "tidewater/pull/93"), checks: "running"), turnStartedAt: now.addingTimeInterval(-3 * 60)),
        ]
        let unread = [
            RemoteSession(id: "demo-unread-feed", title: "Keep the feed anchored", folder: fieldnotes, branch: "feature/anchor-the-activity-feed-scroll-position-for-large-text", lastActivity: now.addingTimeInterval(-9 * 60), status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, pullRequest: RemotePullRequest(number: 139, state: "Open", url: pullRequests.appending(path: "fieldnotes/pull/139"), checks: "passed"), isUnread: true),
            RemoteSession(id: "demo-unread-routes", title: "Review route naming", folder: atlasAPI, branch: "feature/route-names", lastActivity: now.addingTimeInterval(-12 * 60), status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, isUnread: true, isFlagged: true),
        ]
        let pinned = [
            RemoteSession(id: "demo-pinned", title: "Add a printable harbor log", folder: harborLog, branch: "feature/print-log", lastActivity: now.addingTimeInterval(-18 * 60), status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, pullRequest: RemotePullRequest(number: 28, state: "Merged", url: pullRequests.appending(path: "harbor-log/pull/28")), isPinned: true),
        ]
        let today = [
            RemoteSession(id: "demo-starting", title: "New Session", folder: harborLog, branch: nil, lastActivity: now, status: nil, waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false),
            session,
            RemoteSession(id: "demo-shell", title: "Export the tide archive", folder: tidewater, branch: "main", lastActivity: now.addingTimeInterval(-6 * 60), status: "shell", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false),
            RemoteSession(id: "demo-locked", title: "Reconcile vessel records", folder: harborLog, branch: "fix/vessel-records", lastActivity: now.addingTimeInterval(-21 * 60), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: true),
            RemoteSession(id: "demo-draft", title: "Sketch the offline cache", folder: atlasAPI, branch: "draft/offline-cache", lastActivity: now.addingTimeInterval(-28 * 60), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false, pullRequest: RemotePullRequest(number: 67, state: "Draft", url: pullRequests.appending(path: "atlas-api/pull/67"))),
            RemoteSession(id: "demo-closed", title: "Retire the old height table", folder: tidewater, branch: "cleanup/height-table", lastActivity: now.addingTimeInterval(-39 * 60), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false, pullRequest: RemotePullRequest(number: 83, state: "Closed", url: pullRequests.appending(path: "tidewater/pull/83"))),
            RemoteSession(id: "demo-long-title", title: "Investigate why the activity feed loses its place when a reader returns from an entry after the first page refreshes in the background", folder: fieldnotes, branch: "fix/restore-feed-position", lastActivity: now.addingTimeInterval(-55 * 60), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false),
        ]
        let previous = [
            RemoteSession(id: "demo-yesterday-search", title: "Tune the journal search", folder: fieldnotes, branch: "feature/rank-search-results-by-matching-journal-entry-and-tag", lastActivity: yesterday.addingTimeInterval(6 * 3600), status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false),
            RemoteSession(id: "demo-yesterday-watch", title: "Watch the manifest importer", folder: harborLog, branch: "feature/import-manifests", lastActivity: yesterday.addingTimeInterval(2 * 3600), status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, pullRequestWatch: PullRequestWatch(number: 31, since: yesterday)),
            RemoteSession(id: "demo-yesterday-tides", title: "Check the tide station map", folder: tidewater, branch: "main", lastActivity: yesterday, status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false),
        ]
        let older = [
            RemoteSession(id: "demo-older-pagination", title: "Document pagination limits", folder: atlasAPI, branch: "docs/pagination", lastActivity: now.addingTimeInterval(-9 * 86_400), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false),
            RemoteSession(id: "demo-older-fixtures", title: "Refresh the harbor fixtures", folder: harborLog, branch: "main", lastActivity: now.addingTimeInterval(-16 * 86_400), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false),
        ]
        let snoozed = [
            RemoteSession(id: "demo-snoozed", title: "Plan the schema migration", folder: atlasAPI, branch: "feature/schema-migration", lastActivity: now.addingTimeInterval(-3 * 3600), status: "idle", waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false),
        ]
        let done = [
            RemoteSession(id: "demo-done", title: "Ship the harbor log export", folder: harborLog, branch: "feature/export", lastActivity: yesterday, status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false, pullRequest: RemotePullRequest(number: 25, state: "Merged", url: pullRequests.appending(path: "harbor-log/pull/25")), isFlagged: true),
        ]
        return [
            RemoteGroup(id: "attention", title: "Needs You", sessions: attention),
            RemoteGroup(id: "working", title: "Working", sessions: working),
            RemoteGroup(id: "unread", title: "Unread", sessions: unread),
            RemoteGroup(id: "pinned", title: "Pinned", sessions: pinned),
            RemoteGroup(id: "recent:today", title: "Today", sessions: today, isCollapsed: false, visibleCount: 6),
            RemoteGroup(id: "recent:yesterday", title: "Yesterday", sessions: previous, isCollapsed: false),
            RemoteGroup(id: "recent:older", title: "Older", sessions: older, isCollapsed: true),
            RemoteGroup(id: RemoteTriageFeature.snoozedGroupID, title: "Snoozed", sessions: snoozed, isCollapsed: false),
            RemoteGroup(id: RemoteTriageFeature.doneGroupID, title: "Done", sessions: done, isCollapsed: false),
        ]
    }
    #endif

    func retryNow() {
        guard state == .reconnecting, task == nil else { return }

        retry?.cancel()
        resume()
    }

    func refresh() async {
        let before = sessionsReceived
        let deadline = ContinuousClock.now + .seconds(5)
        send(.refresh)
        loadUsage()
        while sessionsReceived == before, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func suspend() {
        guard state == .connected || state == .reconnecting else { return }

        retry?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .reconnecting
    }

    func disconnect() {
        retry?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        lastSent = nil
        pending = [:]
        pendingAttachments = [:]
        entries = [:]
        queued = [:]
        subscribedSessionID = nil
        state = .disconnected(nil)
    }

    func subscribe(to sessionID: String) {
        if let subscribedSessionID, subscribedSessionID != sessionID {
            reconcilePending(in: subscribedSessionID, queued: [])
        }
        subscribedSessionID = sessionID
        send(.subscribe(sessionID: sessionID))
    }

    func requestTaskDetail(_ taskID: String, in sessionID: String) {
        guard features.contains(RemoteTaskDetail.feature) else { return }

        send(.taskDetail(sessionID: sessionID, taskID: taskID))
    }

    func loadPullRequest(of sessionID: String) {
        send(.pullRequest(sessionID: sessionID))
    }

    func loadUsage() {
        guard features.contains(RemoteUsageFeature.name) else { return }

        send(.usage)
        if features.contains(RemoteCodexUsageFeature.name) { send(.codexUsage) }
    }

    func loadChanges(of sessionID: String) {
        send(.changes(sessionID: sessionID))
    }

    func loadSlashCommands(for sessionID: String) {
        guard features.contains(RemoteSlashCommand.feature), !requestedSlashCommands.contains(sessionID), send(.commands(sessionID: sessionID)) else { return }

        requestedSlashCommands.insert(sessionID)
    }

    func loadImage(_ id: String, variant: RemoteImageVariant) {
        let key = ImageKey(id: id, variant: variant)
        guard images[key] == nil, features.contains(RemoteImagesFeature.name), let subscribedSessionID else { return }

        images[key] = .loading
        if !send(.image(sessionID: subscribedSessionID, id: id, variant: variant)) { images[key] = nil }
    }

    func loadDiff(_ key: ChangeKey) {
        send(.changeDiff(sessionID: key.sessionID, path: key.path, isCommitted: key.isCommitted))
    }

    @discardableResult
    func send(_ message: RemoteClientMessage) -> Bool {
        guard let task, state == .connected, let data = try? JSONEncoder().encode(message) else { return false }

        Task { try? await task.send(.string(String(decoding: data, as: UTF8.self))) }
        return true
    }

    func sendDraft(to sessionID: String) -> Bool {
        let text = draftTexts[sessionID, default: ""]
        let attachments = draftAttachments[sessionID, default: []].enumerated().sorted { lhs, rhs in
            let positions = [lhs, rhs].map { $0.element.number.flatMap { text.range(of: "[Image #\($0)]")?.lowerBound } }
            guard let first = positions[0] else { return positions[1] == nil ? lhs.offset < rhs.offset : true }
            guard let second = positions[1] else { return false }

            return first < second
        }.map(\.element)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }

        draftTexts[sessionID] = nil
        draftAttachments[sessionID] = nil
        return sendPrompt(text, attachments: attachments, to: sessionID)
    }

    func retryPrompt(_ prompt: PendingPrompt, in sessionID: String) {
        guard state == .connected, let index = pending[sessionID]?.firstIndex(where: { $0.sentAt == prompt.sentAt && $0.isFailed }) else { return }

        let attachments = pendingAttachments[sessionID]?[prompt.sentAt] ?? []
        pendingAttachments[sessionID]?[prompt.sentAt] = nil
        _ = sendPrompt(prompt.text, attachments: attachments, to: sessionID, replacing: index)
    }

    func dismissPrompt(_ prompt: PendingPrompt, in sessionID: String) {
        pending[sessionID]?.removeAll { $0.sentAt == prompt.sentAt && $0.isFailed }
        reconcilePending(in: sessionID)
    }

    private func sendPrompt(_ text: String, attachments: [Attachment], to sessionID: String, replacing index: Int? = nil) -> Bool {
        let entries = promptEntries(in: sessionID)
        let baseline = PendingPrompts.recordedCount(text: text, attachmentCount: attachments.count, entries: entries)
        let promptBaseline = entries.count { $0.name != "bash" }
        let date = Date.now
        let prompt = PendingPrompt(text: text, sentAt: date, attachmentCount: attachments.count, baseline: baseline, promptBaseline: promptBaseline, isFailed: state != .connected || task == nil)
        pendingAttachments[sessionID, default: [:]][date] = attachments
        if let index {
            pending[sessionID]?[index] = prompt
        } else {
            pending[sessionID, default: []].append(prompt)
        }
        guard let task, !prompt.isFailed else { return false }

        lastSent = (sessionID, date)
        let message = RemoteClientMessage.prompt(sessionID: sessionID, text: text, attachments: attachments.isEmpty ? nil : attachments.map(\.id))
        Task { [weak self] in
            do {
                try await task.send(.string(String(decoding: JSONEncoder().encode(message), as: UTF8.self)))
            } catch {
                self?.failPrompt(sentAt: date, in: sessionID)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PendingPrompts.grace + 1))
            self?.reconcilePending(in: sessionID)
        }
        return true
    }

    private func failPrompt(sentAt: Date, in sessionID: String) {
        guard let index = pending[sessionID]?.firstIndex(where: { $0.sentAt == sentAt }) else { return }

        pending[sessionID]?[index].isFailed = true
    }

    private func reconcilePending(in sessionID: String, queued: [String]? = nil) {
        guard let prompts = pending[sessionID] else { return }

        let kept = PendingPrompts.reconcile(prompts, entries: promptEntries(in: sessionID), queued: queued ?? self.queued[sessionID] ?? [], now: .now)
        pendingAttachments[sessionID] = kept.isEmpty ? nil : pendingAttachments[sessionID]?.filter { date, _ in kept.contains { $0.sentAt == date } }
        if kept.isEmpty || kept != prompts { pending[sessionID] = kept.isEmpty ? nil : kept }
    }

    private func promptEntries(in sessionID: String) -> [RemoteEntry] {
        (entries[sessionID] ?? []).compactMap { entry in
            guard entry.kind == .prompt else { return nil }
            guard let images = entry.images, !images.isEmpty, entry.text.firstMatch(of: PromptTextPart.imageToken) == nil else { return entry }

            let tokens = (entry.imageNumbers ?? Array(1...images.count)).map { "[Image #\($0)]" }.joined(separator: " ")
            return RemoteEntry(id: entry.id, kind: .prompt, text: "\(tokens) \(entry.text)", name: entry.name, date: entry.date)
        }
    }

    func upload(_ data: Data, id: String, name: String) async {
        uploads[id] = .uploading
        guard let task, state == .connected, features.contains(RemoteUpload.feature) else {
            uploads[id] = .failed("Not connected to Berth")
            return
        }

        do {
            for offset in stride(from: 0, to: max(data.count, 1), by: RemoteUpload.chunkBytes) {
                let end = min(offset + RemoteUpload.chunkBytes, data.count)
                let message = RemoteClientMessage.upload(id: id, name: name, offset: offset, chunk: data.subdata(in: offset..<end), isLast: end == data.count)
                try await task.send(.string(String(decoding: JSONEncoder().encode(message), as: UTF8.self)))
            }
        } catch {
            uploads[id] = .failed("The upload was interrupted")
        }
    }

    private static func save(token: String) -> Bool {
        SecItemDelete(tokenQuery as CFDictionary)
        let item = tokenQuery.merging([kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func open(_ url: URL, token: String) {
        retry?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        self.task = task
        task.resume()
        Task { await run(task, token: token) }
    }

    private func run(_ task: URLSessionWebSocketTask, token: String) async {
        do {
            while true {
                guard case let .string(text) = try await task.receive() else { continue }
                guard self.task === task else { return }

                let message = try JSONDecoder().decode(RemoteServerMessage.self, from: Data(text.utf8))
                guard case let .challenge(nonce) = message else {
                    apply(message)
                    continue
                }

                let hmac = Data(HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: Data(token.utf8))))
                try await task.send(.string(String(decoding: JSONEncoder().encode(RemoteClientMessage.auth(hmac: hmac)), as: UTF8.self)))
            }
        } catch {
            guard self.task === task else { return }

            self.task = nil
            if task.closeCode == .policyViolation {
                state = .disconnected("Berth rejected the token.")
                return
            }
            if state == .connecting {
                state = .disconnected("Couldn’t connect. Check the address.")
                return
            }

            state = .reconnecting
            let delay = [1, 2, 5, 10][min(failures, 3)]
            failures += 1
            retry = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                resume()
            }
        }
    }

    private func apply(_ message: RemoteServerMessage) {
        switch message {
        case let .sessions(groups, folders, features):
            let previousFeatures = self.features
            sessionsReceived += 1
            self.groups = groups
            self.folders = folders
            self.features = features ?? []
            if !self.features.contains(RemoteUsageFeature.name) { usage = nil }
            if !self.features.contains(RemoteCodexUsageFeature.name) { codexUsage = nil }
            guard state != .connected else {
                if [RemoteUsageFeature.name, RemoteCodexUsageFeature.name].contains(where: { self.features.contains($0) && !previousFeatures.contains($0) }) {
                    loadUsage()
                }
                return
            }

            state = .connected
            failures = 0
            loadUsage()
            if let subscribedSessionID { send(.subscribe(sessionID: subscribedSessionID)) }

        case let .transcript(sessionID, chunk, isContinuation, queued, activity):
            entries[sessionID] = (isContinuation ? entries[sessionID] ?? [] : []) + chunk
            self.queued[sessionID] = queued ?? []
            self.activity[sessionID] = activity
            reconcilePending(in: sessionID)

        case let .opened(sessionID):
            openedSessionID = sessionID

        case let .notice(message):
            notice = message
            if let lastSent, Date.now.timeIntervalSince(lastSent.date) < 5 {
                failPrompt(sentAt: lastSent.date, in: lastSent.sessionID)
            }
            lastSent = nil

        case let .taskDetail(_, taskID, detail):
            taskDetails[taskID] = detail

        case let .uploaded(id, error):
            uploads[id] = error.map(UploadState.failed) ?? .done

        case let .pullRequest(sessionID, detail):
            pullRequests[sessionID] = detail.map(PullRequestLoad.loaded) ?? .failed

        case let .searchResults(query, hits, isIndexing):
            transcriptSearch = (query, hits, isIndexing)

        case let .changes(sessionID, changes):
            self.changes[sessionID] = changes.map(ChangesLoad.loaded) ?? .failed

        case let .image(_, id, variant, data):
            images[ImageKey(id: id, variant: variant)] = data.map(ImageLoad.loaded) ?? .failed

        case let .changeDiff(sessionID, path, isCommitted, diff):
            diffs[ChangeKey(sessionID: sessionID, path: path, isCommitted: isCommitted)] = diff.map(DiffLoad.loaded) ?? .failed

        case let .usage(usage):
            if features.contains(RemoteUsageFeature.name) { self.usage = usage }

        case let .commands(sessionID, commands):
            slashCommands[sessionID] = commands.map { SlashCommand($0) }

        case let .codexUsage(usage):
            if features.contains(RemoteCodexUsageFeature.name) { codexUsage = usage }

        case .challenge:
            return
        }
    }
}
