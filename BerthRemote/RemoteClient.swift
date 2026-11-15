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
            for (id, upload) in uploads where upload == .uploading { uploads[id] = .failed("The connection dropped") }
        }
    }
    private(set) var groups: [RemoteGroup] = []
    private(set) var folders: [String] = []
    private(set) var entries: [String: [RemoteEntry]] = [:]
    private(set) var queued: [String: [String]] = [:]
    private(set) var activity: [String: RemoteActivity] = [:]
    private(set) var features: [String] = []
    private(set) var uploads: [String: UploadState] = [:]
    var notice: String?
    var openedSessionID: String?
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var subscribedSessionID: String?

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

    func send(_ message: RemoteClientMessage) {
        guard let task, state == .connected, let data = try? JSONEncoder().encode(message) else { return }
        Task { try? await task.send(.string(String(decoding: data, as: UTF8.self))) }
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
                try await task.send(.string(String(decoding: try JSONEncoder().encode(message), as: UTF8.self)))
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
                try await task.send(.string(String(decoding: try JSONEncoder().encode(RemoteClientMessage.auth(hmac: hmac)), as: UTF8.self)))
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
        case let .uploaded(id, error):
            uploads[id] = error.map(UploadState.failed) ?? .done
        case .challenge:
            return
        }
    }
}
