import Darwin
import Foundation

public enum Capability: String, CaseIterable, Sendable {
    case needsYou, approvals, permissionModes, modelEffortMenu, contextSize, pullRequestLinks, backgroundTasks, idleUnload, worktrees, remote, conversation, bashMode
}

public enum LaunchStart: Sendable {
    case new, newInWorktree, resume, attach
}

public struct LaunchOptions: Sendable {
    public let model: String?
    public let effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }
}

public struct LiveProbe: Sendable {
    public struct Tab: Sendable {
        public let sessionID: String
        public let cwd: String
        public let terminalTitle: String
        public let opened: Date
        public let transcript: URL?

        public init(sessionID: String, cwd: String, terminalTitle: String, opened: Date, transcript: URL?) {
            self.sessionID = sessionID
            self.cwd = cwd
            self.terminalTitle = terminalTitle
            self.opened = opened
            self.transcript = transcript
        }
    }

    public let directory: URL
    public let tabs: [Tab]

    public init(directory: URL, tabs: [Tab]) {
        self.directory = directory
        self.tabs = tabs
    }
}

public struct Harness: Sendable {
    public enum LiveSource: Sendable {
        case sessionFiles, tabSignals
    }

    public typealias Claim = @Sendable (_ opened: Date, _ cwd: String, _ sessions: [SessionSummary], _ claimed: Set<String>) -> SessionSummary?
    public typealias ReadTranscript = @Sendable (_ url: URL, _ offset: Int?, _ queue: [String]) -> TranscriptTail.Chunk?

    public typealias LocateSubagent = @Sendable (_ root: URL, _ session: URL, _ agentID: String?, _ toolUseID: String?) -> Subagent?

    public let agent: Agent
    public let name: String
    public let asset: String
    public let isOptIn: Bool
    public let capabilities: Set<Capability>
    public let liveSource: LiveSource
    public let readLive: @Sendable (LiveProbe) -> [LiveSession]
    public let isStatusTitle: @Sendable (String) -> Bool
    public let command: @Sendable (LaunchStart, LaunchOptions) -> String
    public let claim: Claim?
    public let readTranscript: ReadTranscript?

    public let approvalKeys: RemoteApprovalKeys
    public let readApproval: (@Sendable (URL) -> PendingApproval?)?
    public let readTasks: (@Sendable (_ root: URL, _ session: URL) -> [RemoteTask])?
    public let locateSubagent: LocateSubagent
    public let readSubagentTranscript: ReadTranscript
    public let summaryContext: (@Sendable (SessionSummary) -> RemoteContext?)?
    public let readyTerminalProcess: (@Sendable (String) -> (name: String, excludedChildren: Set<String>)?)?

    public var usesTranscriptActivity: Bool { supports(.backgroundTasks) && readTasks == nil }

    public var claimsNewSession: Bool { claim != nil }

    public func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }

    public static let claude = Self(
        agent: .claude,
        name: "Claude",
        asset: "HarnessClaude",
        isOptIn: false,
        capabilities: Set(Capability.allCases),
        liveSource: .sessionFiles,
        readLive: { probe in
            LiveSession.load(from: probe.directory.appending(path: "sessions")) { kill($0, 0) == 0 || errno == EPERM }
        },
        isStatusTitle: { _ in false },
        command: { start, _ in ClaudeLaunch.command(start) },
        claim: nil,
        readTranscript: { TranscriptTail.read($0, after: $1, queue: $2) },
        approvalKeys: RemoteApprovalKeys(approve: .digit1, always: nil, deny: .escape),
        readApproval: nil,
        readTasks: nil,
        locateSubagent: { _, session, agentID, toolUseID in Subagent.locate(session: session, agentID: agentID, toolUseID: toolUseID) },
        readSubagentTranscript: { TranscriptTail.read($0, after: $1, queue: $2, includeSidechain: true) },
        summaryContext: nil,
        readyTerminalProcess: nil
    )

    public static let codex = Self(
        agent: .codex,
        name: "Codex",
        asset: "HarnessCodex",
        isOptIn: true,
        capabilities: [.conversation, .contextSize, .pullRequestLinks, .needsYou, .approvals, .backgroundTasks, .idleUnload, .worktrees, .remote],
        liveSource: .tabSignals,
        readLive: CodexLive.sessions,
        isStatusTitle: { CodexRunState(title: $0) != nil },
        command: CodexLaunch.command,
        claim: { CodexLaunch.claim(for: $0, cwd: $1, in: $2, excluding: $3) },
        readTranscript: CodexTranscript.read,
        approvalKeys: RemoteApprovalKeys(approve: .digit1, always: .digit2, deny: .digit3),
        readApproval: CodexTranscript.pendingApproval,
        readTasks: CodexSubagents.tasks,
        locateSubagent: CodexSubagents.locate,
        readSubagentTranscript: CodexTranscript.read,
        summaryContext: CodexModels.context,
        readyTerminalProcess: { CodexRunState(title: $0) == .ready ? ("codex", ["codex-code-mode-host"]) : nil }
    )

    public static let all = [claude, codex]
}

public extension Agent {
    var harness: Harness {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}
