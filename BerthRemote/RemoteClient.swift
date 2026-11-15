import Foundation
import Observation

@Observable
final class RemoteClient {
    enum State: Equatable {
        case disconnected(String?)
        case connecting
        case connected
    }

    private(set) var state = State.disconnected(nil)
    private(set) var groups: [RemoteGroup] = []
    private(set) var folders: [String] = []
    private(set) var entries: [String: [RemoteEntry]] = [:]
    var notice: String?
    var openedSessionID: String?
    @ObservationIgnored private var task: URLSessionWebSocketTask?

    func connect(to url: URL, token: String) {
        task?.cancel(with: .goingAway, reason: nil)
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
        self.task = task
        state = .connecting
        task.resume()
        Task {
            do {
                try await task.send(.string(String(decoding: try JSONEncoder().encode(RemoteClientMessage.hello(token: token)), as: UTF8.self)))
                while true {
                    guard case let .string(text) = try await task.receive() else { continue }
                    apply(try JSONDecoder().decode(RemoteServerMessage.self, from: Data(text.utf8)))
                }
            } catch {
                guard self.task === task else { return }
                state = .disconnected(state == .connecting ? "Couldn’t connect. Check the address and token." : error.localizedDescription)
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected(nil)
    }

    func send(_ message: RemoteClientMessage) {
        guard let task, let data = try? JSONEncoder().encode(message) else { return }
        Task { try? await task.send(.string(String(decoding: data, as: UTF8.self))) }
    }

    private func apply(_ message: RemoteServerMessage) {
        switch message {
        case let .sessions(groups, folders):
            self.groups = groups
            self.folders = folders
            state = .connected
        case let .transcript(sessionID, chunk, isContinuation):
            entries[sessionID] = (isContinuation ? entries[sessionID] ?? [] : []) + chunk
        case let .opened(sessionID):
            openedSessionID = sessionID
        case let .notice(message):
            notice = message
        }
    }
}
