import Darwin
import Foundation

public enum ControlOp: String, Codable, Sendable {
    case list = "ls", open, openSession = "open-session", openPath = "open-path", openURL = "open-url", send, capture, close, wait, showPullRequest = "show-pr"
    case browserTabs = "browser-tabs", browserScreenshot = "browser-screenshot", browserConsole = "browser-console", browserURL = "browser-url"
    case browserReload = "browser-reload", browserNavigate = "browser-navigate", browserText = "browser-text"

    public var isBrowser: Bool { rawValue.hasPrefix("browser-") }
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
    public var url: String?
    public var fullPage: Bool?
    public var since: Int?

    public init(token: String, caller: String, operation: ControlOp, tab: String? = nil, cwd: String? = nil, path: String? = nil, command: String? = nil, text: String? = nil, enter: Bool? = nil, background: Bool? = nil, timeout: Double? = nil, pullRequest: Int? = nil, repository: String? = nil, repositoryPath: String? = nil, url: String? = nil, fullPage: Bool? = nil, since: Int? = nil) {
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
        self.url = url
        self.fullPage = fullPage
        self.since = since
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

public struct ControlBrowserTab: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: String?
    public let loading: Bool
    public let active: Bool

    public init(id: String, title: String, url: String?, loading: Bool, active: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.loading = loading
        self.active = active
    }
}

public struct ControlConsoleEntry: Codable, Equatable, Sendable {
    public static let bufferCapacity = 500

    public let sequence: Int
    public let level: String
    public let text: String
    public let timestamp: Date

    public init(sequence: Int, level: String, text: String, timestamp: Date) {
        self.sequence = sequence
        self.level = level
        self.text = text
        self.timestamp = timestamp
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public var succeeded: Bool
    public var error: String?
    public var tabs: [ControlTab]?
    public var tab: String?
    public var text: String?
    public var exit: Int32?
    public var browserTabs: [ControlBrowserTab]?
    public var console: [ControlConsoleEntry]?
    public var consoleHasMore: Bool?

    public init(succeeded: Bool = true, error: String? = nil, tabs: [ControlTab]? = nil, tab: String? = nil, text: String? = nil, exit: Int32? = nil, browserTabs: [ControlBrowserTab]? = nil, console: [ControlConsoleEntry]? = nil, consoleHasMore: Bool? = nil) {
        self.succeeded = succeeded
        self.error = error
        self.tabs = tabs
        self.tab = tab
        self.text = text
        self.exit = exit
        self.browserTabs = browserTabs
        self.console = console
        self.consoleHasMore = consoleHasMore
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

    /// A fresh unguessable control token for a new or invalid token file.
    public static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    public static func persistentToken(directory: String) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory, 0o700) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

        let descriptor = open(directory + "/token", O_RDWR | O_CREAT | O_EXLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }

        guard fchmod(descriptor, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

        if let data = try file.read(upToCount: 65), let saved = String(data: data, encoding: .utf8), saved.wholeMatch(of: /[0-9A-Fa-f]{64}/) != nil {
            return saved
        }

        let token = makeToken()
        try file.seek(toOffset: 0)
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: Data(token.utf8))
        return token
    }

    public static func variables(socketPath: String, token: String, tab: String) -> [String: String] {
        [socket: socketPath, Self.token: token, Self.tab: tab]
    }
}
