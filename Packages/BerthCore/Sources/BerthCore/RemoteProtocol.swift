import Foundation

public struct RemoteApprovalKeys: Codable, Sendable, Hashable {
    public let approve: RemoteKey
    public let always: RemoteKey?
    public let deny: RemoteKey
}

public struct RemoteAgent: Codable, Sendable, Hashable {
    public let name: String
    public let asset: String
    public let canChangeSettings: Bool
    public let canAttach: Bool
    public let canRunBash: Bool?
    public let approvalKeys: RemoteApprovalKeys?

    private enum CodingKeys: String, CodingKey {
        case name, canChangeSettings, canAttach, canRunBash, approvalKeys
        case asset = "glyph"
    }

    public init(name: String, asset: String, canChangeSettings: Bool, canAttach: Bool, canRunBash: Bool? = nil, approvalKeys: RemoteApprovalKeys? = nil) {
        self.name = name
        self.asset = asset
        self.canChangeSettings = canChangeSettings
        self.canAttach = canAttach
        self.canRunBash = canRunBash
        self.approvalKeys = approvalKeys
    }
}

public struct RemoteSession: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let folder: String
    public let branch: String?
    public let lastActivity: Date
    public let status: String?
    public let waitingFor: String?
    public let waitingSince: Double?
    public let isOpen: Bool
    public let isLocked: Bool
    public let lastPrompt: Date?
    public let pullRequest: RemotePullRequest?
    public let isUnread: Bool?
    public let turnStartedAt: Date?
    public let agent: RemoteAgent?
    public let pullRequestWatch: PullRequestWatch?
    public let isPinned: Bool?

    public init(id: String, title: String, folder: String, branch: String?, lastActivity: Date, status: String?, waitingFor: String?, waitingSince: Double?, isOpen: Bool, isLocked: Bool, lastPrompt: Date? = nil, pullRequest: RemotePullRequest? = nil, isUnread: Bool? = nil, turnStartedAt: Date? = nil, agent: RemoteAgent? = nil, pullRequestWatch: PullRequestWatch? = nil, isPinned: Bool? = nil) {
        self.id = id
        self.title = title
        self.folder = folder
        self.branch = branch
        self.lastActivity = lastActivity
        self.status = status
        self.waitingFor = waitingFor
        self.waitingSince = waitingSince
        self.isOpen = isOpen
        self.isLocked = isLocked
        self.lastPrompt = lastPrompt
        self.pullRequest = pullRequest
        self.isUnread = isUnread
        self.turnStartedAt = turnStartedAt
        self.agent = agent
        self.pullRequestWatch = pullRequestWatch
        self.isPinned = isPinned
    }
}

public struct PullRequestWatch: Codable, Sendable, Hashable {
    public let number: Int?
    public let repository: String?
    public let since: Date

    public init(number: Int?, repository: String? = nil, since: Date) {
        self.number = number
        self.repository = repository
        self.since = since
    }

    public var expiresAt: Date { since.addingTimeInterval(7 * 86_400) }

    public var title: String {
        number.map { "Watching #\($0)" } ?? "Watching PR"
    }
}

public struct RemotePullRequest: Codable, Sendable, Hashable {
    public let number: Int
    public let state: String
    public let url: URL
    public let checks: String?

    public init(number: Int, state: String, url: URL, checks: String? = nil) {
        self.number = number
        self.state = state
        self.url = url
        self.checks = checks
    }
}

public struct RemotePullRequestDetail: Codable, Sendable, Hashable {
    public let number: Int
    public let title: String
    public let state: String
    public let url: URL
    public let repository: String?
    public let head: String?
    public let base: String?
    public let checks: String?
    public let checksPassed: Int?
    public let checksFailed: Int?
    public let checksRunning: Int?
    public let reviewDecision: String?
    public let unresolvedThreads: Int?
    public let additions: Int?
    public let deletions: Int?
    public let changedFiles: Int?
    public let commits: Int?

    public init(number: Int, title: String, state: String, url: URL, repository: String?, head: String?, base: String?, checks: String?, checksPassed: Int?, checksFailed: Int?, checksRunning: Int?, reviewDecision: String?, unresolvedThreads: Int?, additions: Int?, deletions: Int?, changedFiles: Int?, commits: Int?) {
        self.number = number
        self.title = title
        self.state = state
        self.url = url
        self.repository = repository
        self.head = head
        self.base = base
        self.checks = checks
        self.checksPassed = checksPassed
        self.checksFailed = checksFailed
        self.checksRunning = checksRunning
        self.reviewDecision = reviewDecision
        self.unresolvedThreads = unresolvedThreads
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.commits = commits
    }
}

public struct RemoteGroup: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let sessions: [RemoteSession]
    public let isCollapsed: Bool?
    public let visibleCount: Int?

    public init(id: String, title: String, sessions: [RemoteSession], isCollapsed: Bool? = nil, visibleCount: Int? = nil) {
        self.id = id
        self.title = title
        self.sessions = sessions
        self.isCollapsed = isCollapsed
        self.visibleCount = visibleCount
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
    public let date: Date?
    public let detail: String?
    public let images: [Data]?
    public let imageNumbers: [Int]?
    public var imageRefs: [RemoteImageRef]?
    public var shellOutput: String?
    public var shellError: String?

    public init(id: String, kind: Kind, text: String, toolID: String? = nil, name: String? = nil, command: String? = nil, filePath: String? = nil, oldText: String? = nil, newText: String? = nil, isError: Bool = false, date: Date? = nil, detail: String? = nil, images: [Data]? = nil, imageNumbers: [Int]? = nil, imageRefs: [RemoteImageRef]? = nil) {
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
        self.date = date
        self.detail = detail
        self.images = images
        self.imageNumbers = imageNumbers
        self.imageRefs = imageRefs
    }
}

public struct RemoteImageRef: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let bytes: Int

    public init(id: String, bytes: Int) {
        self.id = id
        self.bytes = bytes
    }
}

public enum RemoteImageVariant: String, Codable, Sendable {
    case thumbnail, full
}

public nonisolated enum RemoteImagesFeature {
    public static let name = "images"
    public static let maxSourceBytes = 20 << 20
    public static let maxReplyBytes = 700_000
}

public struct RemoteApproval: Codable, Sendable, Hashable {
    public let call: RemoteEntry
    public let waitingSince: Double?

    public init(call: RemoteEntry, waitingSince: Double?) {
        self.call = call
        self.waitingSince = waitingSince
    }
}

public struct RemoteActivity: Codable, Sendable, Hashable {
    public let tasks: [RemoteTask]
    public let context: RemoteContext?
    public let approval: RemoteApproval?

    public init(tasks: [RemoteTask], context: RemoteContext?, approval: RemoteApproval? = nil) {
        self.tasks = tasks
        self.context = context
        self.approval = approval
    }
}

public struct RemoteTask: Codable, Sendable, Hashable, Identifiable {
    public static let agent = "agent"
    public static let shell = "shell"
    public static let monitor = "monitor"

    public let id: String
    public let kind: String
    public let title: String
    public let started: Date
    public let command: String?
    public let agentType: String?
    public let toolCount: Int?
    public let tokens: Int?
    public let call: RemoteToolCall?
    public let toolUseID: String?

    public init(id: String, kind: String, title: String, started: Date, command: String? = nil, agentType: String? = nil, toolCount: Int? = nil, tokens: Int? = nil, call: RemoteToolCall? = nil, toolUseID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.started = started
        self.command = command
        self.agentType = agentType
        self.toolCount = toolCount
        self.tokens = tokens
        self.call = call
        self.toolUseID = toolUseID
    }
}

public extension RemoteTask {
    var symbol: String {
        kind == Self.agent ? "person.2" : kind == Self.monitor ? "eye" : "terminal"
    }

    var kindName: String {
        kind == Self.agent ? "Agent" : kind == Self.shell ? "Shell" : kind == Self.monitor ? "Monitor" : "Task"
    }

    static func summary(of tasks: [Self]) -> String {
        let counts = [([agent], "agent", "agents"), ([shell], "shell", "shells"), ([monitor], "monitor", "monitors")]
            .compactMap { kinds, one, many -> String? in
                let count = tasks.count { kinds.contains($0.kind) }
                return count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
            }
        return counts.isEmpty ? "\(tasks.count) running" : counts.joined(separator: " · ")
    }
}

public struct RemoteToolCall: Codable, Sendable, Hashable {
    public let name: String
    public let summary: String
    public let date: Date?

    public init(name: String, summary: String, date: Date? = nil) {
        self.name = name
        self.summary = summary
        self.date = date
    }

    public var phrase: String {
        let verbs = ["Grep": "Searching for", "Glob": "Finding", "Read": "Reading", "Edit": "Editing", "Write": "Writing", "Bash": "Running", "WebFetch": "Fetching", "WebSearch": "Searching the web for"]
        return [verbs[name] ?? name, summary].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct RemoteTaskDetail: Codable, Sendable, Hashable {
    public static let feature = "taskDetail"

    public let output: String?
    public let calls: [RemoteToolCall]?
    public let reply: String?

    public init(output: String? = nil, calls: [RemoteToolCall]? = nil, reply: String? = nil) {
        self.output = output
        self.calls = calls
        self.reply = reply
    }
}

public struct RemoteContext: Codable, Sendable, Hashable {
    public let model: String
    public let tokens: Int?
    public let window: Int?
    public let date: Date
    public let compactions: Int
    public let lastCompaction: Date?
    public let effort: String?

    public init(model: String, tokens: Int?, window: Int?, date: Date, compactions: Int, lastCompaction: Date?, effort: String? = nil) {
        self.model = model
        self.tokens = tokens
        self.window = window
        self.date = date
        self.compactions = compactions
        self.lastCompaction = lastCompaction
        self.effort = effort
    }
}

public nonisolated enum RemoteSessionSettingsFeature {
    public static let name = "sessionSettings"
}

public enum ModelChoice: String, Codable, Sendable, CaseIterable {
    case `default`, opus, fable, sonnet, haiku

    public var title: String {
        self == .default ? "Default" : rawValue.capitalized
    }

    public init?(modelID: String) {
        guard let family = Self.allCases.first(where: { $0 != .default && modelID.localizedStandardContains($0.rawValue) }) else { return nil }

        self = family
    }
}

public enum EffortLevel: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max

    public var title: String {
        self == .xhigh ? "Extra High" : rawValue.capitalized
    }
}

public enum RemoteSessionSetting: Codable, Sendable, Hashable {
    case model(ModelChoice)
    case effort(EffortLevel)
}

public enum RemoteKey: String, Codable, Sendable, CaseIterable {
    case enter, escape, shiftTab, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
}

public enum RemoteSessionAction: String, Codable, Sendable {
    case show, pin, unpin, markRead, markUnread, archive, interrupt
}

public nonisolated enum RemoteUpload {
    public static let feature = "upload"
    public static let maxBytes = 20 << 20
    public static let chunkBytes = 512 << 10
}

public nonisolated enum RemotePullRequestFeature {
    public static let name = "pullRequest"
}

public nonisolated enum RemoteSearchFeature {
    public static let name = "search"
    public static let minimumQueryLength = 3
}

public struct RemoteSnippet: Codable, Sendable, Hashable {
    public let text: String
    public let highlights: [Range<Int>]

    public init(text: String, highlights: [Range<Int>]) {
        self.text = text
        self.highlights = highlights
    }
}

public struct RemoteSearchHit: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let folder: String
    public let lastActivity: Date
    public let snippets: [RemoteSnippet]

    public init(id: String, title: String, folder: String, lastActivity: Date, snippets: [RemoteSnippet]) {
        self.id = id
        self.title = title
        self.folder = folder
        self.lastActivity = lastActivity
        self.snippets = snippets
    }
}

public nonisolated enum RemoteUsageFeature {
    public static let name = "usage"
}

public nonisolated enum RemoteCodexUsageFeature {
    public static let name = "codexUsage"
}

public nonisolated enum RemoteChangesFeature {
    public static let name = "changes"
    public static let maxFiles = 200
    public static let maxDiffBytes = 300_000
}

public struct RemoteChangedFile: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let oldPath: String?
    public let status: String
    public let additions: Int?
    public let deletions: Int?

    public var id: String { path }

    public init(path: String, oldPath: String?, status: String, additions: Int?, deletions: Int?) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }
}

public struct RemoteChanges: Codable, Sendable, Hashable {
    public let branch: String
    public let base: String?
    public let uncommitted: [RemoteChangedFile]
    public let committed: [RemoteChangedFile]
    public let isTruncated: Bool

    public init(branch: String, base: String?, uncommitted: [RemoteChangedFile], committed: [RemoteChangedFile], isTruncated: Bool) {
        self.branch = branch
        self.base = base
        self.uncommitted = uncommitted
        self.committed = committed
        self.isTruncated = isTruncated
    }
}

public struct RemoteDiffLine: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case context, added, removed, hunk
    }

    public let kind: Kind
    public let old: Int?
    public let new: Int?
    public let text: String

    public init(kind: Kind, old: Int?, new: Int?, text: String) {
        self.kind = kind
        self.old = old
        self.new = new
        self.text = text
    }
}

public struct RemoteFileDiff: Codable, Sendable, Hashable {
    public let lines: [RemoteDiffLine]
    public let isBinary: Bool
    public let isTruncated: Bool

    public init(lines: [RemoteDiffLine], isBinary: Bool, isTruncated: Bool) {
        self.lines = lines
        self.isBinary = isBinary
        self.isTruncated = isTruncated
    }
}

public struct RemoteSlashCommand: Codable, Equatable, Sendable {
    public static let feature = "commands"

    public let name: String
    public let summary: String
    public let source: String
    public let requiresArguments: Bool
    public let argumentHint: String?

    public init(name: String, summary: String, source: String, requiresArguments: Bool, argumentHint: String?) {
        self.name = name
        self.summary = summary
        self.source = source
        self.requiresArguments = requiresArguments
        self.argumentHint = argumentHint
    }
}

public enum RemoteCheckout: String, Codable, Sendable {
    case main, worktree
}

public struct RemoteLaunchAgent: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let asset: String
    public let worktreeFolders: [String]

    public init(id: String, name: String, asset: String, worktreeFolders: [String]) {
        self.id = id
        self.name = name
        self.asset = asset
        self.worktreeFolders = worktreeFolders
    }
}

public struct RemoteLaunchOptions: Codable, Sendable, Equatable {
    public static let feature = "launchOptions"

    public let agents: [RemoteLaunchAgent]
    public let defaultAgent: String
    public let startsInWorktree: Bool

    public init(agents: [RemoteLaunchAgent], defaultAgent: String, startsInWorktree: Bool) {
        self.agents = agents
        self.defaultAgent = defaultAgent
        self.startsInWorktree = startsInWorktree
    }
}

public struct RemoteSessionStart: Codable, Sendable, Equatable {
    public let folder: String
    public let prompt: String
    public let agent: String?
    public let checkout: RemoteCheckout?

    public init(folder: String, prompt: String, agent: String? = nil, checkout: RemoteCheckout? = nil) {
        self.folder = folder
        self.prompt = prompt
        self.agent = agent
        self.checkout = checkout
    }
}

public struct RemoteInboxItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case pullRequest, issue
    }

    public let kind: Kind
    public let repository: String
    public let number: Int
    public let title: String
    public let group: String
    public let isOpenable: Bool
    public let updatedAt: Date
    public let author: String?
    public let branch: String?
    public let isDraft: Bool?
    public let checks: String?

    public var id: String { "\(kind.rawValue)/\(repository)#\(number)" }

    public init(kind: Kind, repository: String, number: Int, title: String, group: String, isOpenable: Bool, updatedAt: Date, author: String? = nil, branch: String? = nil, isDraft: Bool? = nil, checks: String? = nil) {
        self.kind = kind
        self.repository = repository
        self.number = number
        self.title = title
        self.group = group
        self.isOpenable = isOpenable
        self.updatedAt = updatedAt
        self.author = author
        self.branch = branch
        self.isDraft = isDraft
        self.checks = checks
    }
}

public struct RemoteInbox: Codable, Sendable, Equatable {
    public static let feature = "inbox"

    public let pullRequests: [RemoteInboxItem]?
    public let issues: [RemoteInboxItem]?

    public init(pullRequests: [RemoteInboxItem]?, issues: [RemoteInboxItem]?) {
        self.pullRequests = pullRequests
        self.issues = issues
    }
}

public enum RemoteClientMessage: Codable, Sendable {
    case auth(hmac: Data)
    case subscribe(sessionID: String)
    case prompt(sessionID: String, text: String, attachments: [String]?)
    case key(sessionID: String, key: RemoteKey, waitingFor: String?, waitingSince: Double?)
    case newSession(folder: String, prompt: String)
    case session(sessionID: String, action: RemoteSessionAction)
    case refresh
    case upload(id: String, name: String, offset: Int, chunk: Data, isLast: Bool)
    case pullRequest(sessionID: String)
    case search(query: String)
    case changes(sessionID: String)
    case changeDiff(sessionID: String, path: String, isCommitted: Bool)
    case usage
    case codexUsage
    case taskDetail(sessionID: String, taskID: String)
    case image(sessionID: String, id: String, variant: RemoteImageVariant)
    case setting(sessionID: String, setting: RemoteSessionSetting, from: RemoteSessionSetting)
    case commands(sessionID: String)
    case launchOptions
    case startSession(RemoteSessionStart)
    case inbox
    case startItem(kind: RemoteInboxItem.Kind, repository: String, number: Int)
}

public enum RemoteServerMessage: Codable, Sendable {
    case challenge(nonce: Data)
    case sessions(groups: [RemoteGroup], folders: [String], features: [String]?)
    case transcript(sessionID: String, entries: [RemoteEntry], isContinuation: Bool, queued: [String]?, activity: RemoteActivity?)
    case opened(sessionID: String)
    case notice(message: String)
    case uploaded(id: String, error: String?)
    case pullRequest(sessionID: String, detail: RemotePullRequestDetail?)
    case searchResults(query: String, hits: [RemoteSearchHit], isIndexing: Bool)
    case changes(sessionID: String, changes: RemoteChanges?)
    case changeDiff(sessionID: String, path: String, isCommitted: Bool, diff: RemoteFileDiff?)
    case usage(PlanUsage?)
    case codexUsage(CodexUsage?)
    case taskDetail(sessionID: String, taskID: String, detail: RemoteTaskDetail?)
    case image(sessionID: String, id: String, variant: RemoteImageVariant, data: Data?)
    case commands(sessionID: String, commands: [RemoteSlashCommand])
    case launchOptions(RemoteLaunchOptions)
    case inbox(RemoteInbox)
}
