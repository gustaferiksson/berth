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
    private(set) var usage: PlanUsage?
    private(set) var codexUsage: CodexUsage?
    private(set) var images: [ImageKey: ImageLoad] = [:]
    private(set) var transcriptSearch: (query: String, hits: [RemoteSearchHit], isIndexing: Bool)?
    private(set) var uploads: [String: UploadState] = [:]
    var draftTexts: [String: String] = UserDefaults.standard.dictionary(forKey: "drafts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(draftTexts.filter { !$0.value.isEmpty }, forKey: "drafts") }
    }

    var draftAttachments: [String: [Attachment]] = [:]
    var notice: String?
    var openedSessionID: String?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var sessionsReceived = 0
    @ObservationIgnored private var subscribedSessionID: String?
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
    func seedDemo() {
        let session = RemoteSession(id: "demo", title: "Refine the activity feed", folder: "/Projects/Fieldnotes", branch: "main", lastActivity: .now, status: "idle", waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false, agent: .legacyClaude)
        state = .connected
        groups = [RemoteGroup(id: "active", title: "Active", sessions: [session])]
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
        if UserDefaults.standard.bool(forKey: "snapshotDemoImageOnly") {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160)).pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            }
            entries[session.id]?.append(RemoteEntry(id: "prompt-image", kind: .prompt, text: "[Image #1]", images: [image], imageNumbers: [1]))
        }
        let resets = Date.now.addingTimeInterval(3 * 3600)
        usage = PlanUsage(windows: [
            UsageWindow(id: "five_hour", title: "Session", length: 5 * 3600, used: 0.42, resetsAt: resets),
            UsageWindow(id: "seven_day", title: "Week", length: 7 * 86_400, used: 0.18, resetsAt: resets.addingTimeInterval(3 * 86_400)),
        ])
        codexUsage = CodexUsage(usage: PlanUsage(windows: [
            UsageWindow(id: "five_hour", title: "Session", length: 5 * 3600, used: 0.67, resetsAt: resets),
            UsageWindow(id: "seven_day", title: "Week", length: 7 * 86_400, used: 0.31, resetsAt: resets.addingTimeInterval(3 * 86_400)),
        ]), recordedAt: .now)
        if !UserDefaults.standard.bool(forKey: "snapshotDemoList") { openedSessionID = session.id }
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
            sessionsReceived += 1
            self.groups = groups
            self.folders = folders
            self.features = features ?? []
            if !self.features.contains(RemoteUsageFeature.name) { usage = nil }
            if !self.features.contains(RemoteCodexUsageFeature.name) { codexUsage = nil }
            guard state != .connected else { return }

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
            self.usage = usage

        case let .codexUsage(usage):
            codexUsage = usage

        case .challenge:
            return
        }
    }
}
