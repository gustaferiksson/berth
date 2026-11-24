import Foundation

public enum ControlOp: String, Codable, Sendable {
    case list = "ls", open, openSession = "open-session", openPath = "open-path", send, capture, close, wait, showPullRequest = "show-pr"
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public var token: String
    public var caller: String
    public var operation: ControlOp
    public var tab: String?
    public var cwd: String?
    public var path: String?
    public var command: String?
    public var text: String?
    public var enter: Bool?
    public var background: Bool?
    public var timeout: Double?
    public var pullRequest: Int?
    public var repository: String?
    public var repositoryPath: String?

    public init(token: String, caller: String, operation: ControlOp, tab: String? = nil, cwd: String? = nil, path: String? = nil, command: String? = nil, text: String? = nil, enter: Bool? = nil, background: Bool? = nil, timeout: Double? = nil, pullRequest: Int? = nil, repository: String? = nil, repositoryPath: String? = nil) {
        self.token = token
        self.caller = caller
        self.operation = operation
        self.tab = tab
        self.cwd = cwd
        self.path = path
        self.command = command
        self.text = text
        self.enter = enter
        self.background = background
        self.timeout = timeout
        self.pullRequest = pullRequest
        self.repository = repository
        self.repositoryPath = repositoryPath
    }
}

public struct ControlTab: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var cwd: String
    public var session: String?
    public var status: String?
    public var openedByYou: Bool

    public init(id: String, kind: String, title: String, cwd: String, session: String? = nil, status: String? = nil, openedByYou: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.session = session
        self.status = status
        self.openedByYou = openedByYou
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var succeeded: Bool
    public var error: String?
    public var tabs: [ControlTab]?
    public var tab: String?
    public var text: String?
    public var exit: Int32?

    public init(succeeded: Bool = true, error: String? = nil, tabs: [ControlTab]? = nil, tab: String? = nil, text: String? = nil, exit: Int32? = nil) {
        self.succeeded = succeeded
        self.error = error
        self.tabs = tabs
        self.tab = tab
        self.text = text
        self.exit = exit
    }

    public static func failure(_ message: String) -> Self {
        Self(succeeded: false, error: message)
    }
}

public enum ControlError: Error, Equatable {
    case pathTooLong
    case socket(Int32)
    case requestTooLarge
    case malformed
    case noReply
}

public enum ControlEnvironment {
    public static let socket = "BERTH_SOCKET"
    public static let tab = "BERTH_TAB_ID"
    public static let token = "BERTH_TOKEN"

    public static func socketPath(directory: String) -> String {
        directory + "/control.sock"
    }

    /// A fresh unguessable per-launch secret.
    public static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    public static func variables(socketPath: String, token: String, tab: String) -> [String: String] {
        [socket: socketPath, Self.token: token, Self.tab: tab]
    }
}
