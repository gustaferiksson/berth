import CryptoKit
import Foundation
import Observation
import Security

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
            for (id, upload) in uploads where upload == .uploading { uploads[id] = .failed("The connection dropped") }
        }
    }

    private(set) var groups: [RemoteGroup] = []
    private(set) var folders: [String] = []
    private(set) var entries: [String: [RemoteEntry]] = [:]
    private(set) var queued: [String: [String]] = [:]
    private(set) var activity: [String: RemoteActivity] = [:]
    private(set) var pullRequests: [String: PullRequestLoad] = [:]
    private(set) var changes: [String: ChangesLoad] = [:]
    private(set) var diffs: [ChangeKey: DiffLoad] = [:]
    private(set) var features: [String] = []
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
    @ObservationIgnored private var lastSent: (sessionID: String, text: String, attachments: [Attachment], date: Date)?

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

    func retryNow() {
        guard state == .reconnecting, task == nil else { return }

        retry?.cancel()
        resume()
    }

    func refresh() async {
        let before = sessionsReceived
        let deadline = ContinuousClock.now + .seconds(5)
        send(.refresh)
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
        state = .disconnected(nil)
    }

    func subscribe(to sessionID: String) {
        subscribedSessionID = sessionID
        send(.subscribe(sessionID: sessionID))
    }

    func loadPullRequest(of sessionID: String) {
        send(.pullRequest(sessionID: sessionID))
    }

    func loadChanges(of sessionID: String) {
        send(.changes(sessionID: sessionID))
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
        let attachments = draftAttachments[sessionID, default: []]
        guard send(.prompt(sessionID: sessionID, text: text, attachments: attachments.isEmpty ? nil : attachments.map(\.id))) else { return false }

        lastSent = (sessionID, text, attachments, .now)
        draftTexts[sessionID] = nil
        draftAttachments[sessionID] = nil
        return true
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
            guard state != .connected else { return }

            state = .connected
            failures = 0
            if let subscribedSessionID { send(.subscribe(sessionID: subscribedSessionID)) }

        case let .transcript(sessionID, chunk, isContinuation, queued, activity):
            entries[sessionID] = (isContinuation ? entries[sessionID] ?? [] : []) + chunk
            self.queued[sessionID] = queued ?? []
            self.activity[sessionID] = activity

        case let .opened(sessionID):
            openedSessionID = sessionID

        case let .notice(message):
            notice = message
            if let lastSent, Date.now.timeIntervalSince(lastSent.date) < 5, draftTexts[lastSent.sessionID, default: ""].isEmpty, draftAttachments[lastSent.sessionID, default: []].isEmpty {
                draftTexts[lastSent.sessionID] = lastSent.text
                draftAttachments[lastSent.sessionID] = lastSent.attachments
            }
            lastSent = nil

        case let .uploaded(id, error):
            uploads[id] = error.map(UploadState.failed) ?? .done

        case let .pullRequest(sessionID, detail):
            pullRequests[sessionID] = detail.map(PullRequestLoad.loaded) ?? .failed

        case let .searchResults(query, hits, isIndexing):
            transcriptSearch = (query, hits, isIndexing)

        case let .changes(sessionID, changes):
            self.changes[sessionID] = changes.map(ChangesLoad.loaded) ?? .failed

        case let .changeDiff(sessionID, path, isCommitted, diff):
            diffs[ChangeKey(sessionID: sessionID, path: path, isCommitted: isCommitted)] = diff.map(DiffLoad.loaded) ?? .failed

        case .challenge:
            return
        }
    }
}
