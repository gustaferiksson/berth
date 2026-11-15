import Foundation

public struct RemoteSession: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let folder: String
    public let branch: String?
    public let lastActivity: Date
    public let status: String?
    public let waitingFor: String?
    public let isOpen: Bool
    public let isLocked: Bool

    public init(id: String, title: String, folder: String, branch: String?, lastActivity: Date, status: String?, waitingFor: String?, isOpen: Bool, isLocked: Bool) {
        self.id = id
        self.title = title
        self.folder = folder
        self.branch = branch
        self.lastActivity = lastActivity
        self.status = status
        self.waitingFor = waitingFor
        self.isOpen = isOpen
        self.isLocked = isLocked
    }
}

public struct RemoteGroup: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let sessions: [RemoteSession]

    public init(id: String, title: String, sessions: [RemoteSession]) {
        self.id = id
        self.title = title
        self.sessions = sessions
    }
}

public struct RemoteEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case prompt, reply, toolUse, toolResult
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let toolID: String?
    public let name: String?
    public let command: String?
    public let filePath: String?
    public let oldText: String?
    public let newText: String?
    public let isError: Bool

    public init(id: String, kind: Kind, text: String, toolID: String? = nil, name: String? = nil, command: String? = nil, filePath: String? = nil, oldText: String? = nil, newText: String? = nil, isError: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolID = toolID
        self.name = name
        self.command = command
        self.filePath = filePath
        self.oldText = oldText
        self.newText = newText
        self.isError = isError
    }
}

public enum RemoteKey: String, Codable, Sendable, CaseIterable {
    case enter, escape, shiftTab, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
}

public enum RemoteClientMessage: Codable, Sendable {
    case auth(hmac: Data)
    case subscribe(sessionID: String)
    case prompt(sessionID: String, text: String)
    case key(sessionID: String, key: RemoteKey, waitingFor: String?)
    case newSession(folder: String, prompt: String)
}

public enum RemoteServerMessage: Codable, Sendable {
    case challenge(nonce: Data)
    case sessions(groups: [RemoteGroup], folders: [String])
    case transcript(sessionID: String, entries: [RemoteEntry], isContinuation: Bool)
    case opened(sessionID: String)
    case notice(message: String)
}
