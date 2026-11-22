import Darwin
import Foundation

public enum Capability: String, CaseIterable, Sendable {
    case needsYou, approvals, modelEffortMenu, contextSize, pullRequestLinks, backgroundTasks, idleUnload, worktrees, remote, conversation
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

    public let agent: Agent
    public let name: String
    public let glyph: String
    public let isOptIn: Bool
    public let capabilities: Set<Capability>
    public let liveSource: LiveSource
    public let readLive: @Sendable (LiveProbe) -> [LiveSession]
    public let isStatusTitle: @Sendable (String) -> Bool
    public let command: @Sendable (LaunchStart, LaunchOptions) -> String
    public let claim: Claim?
    public let readTranscript: ReadTranscript?

    public var claimsNewSession: Bool { claim != nil }

    public func supports(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }

    public static let claude = Self(
        agent: .claude,
        name: "Claude",
        glyph: "sparkle",
        isOptIn: false,
        capabilities: Set(Capability.allCases),
        liveSource: .sessionFiles,
        readLive: { probe in
            LiveSession.load(from: probe.directory.appending(path: "sessions")) { kill($0, 0) == 0 || errno == EPERM }
        },
        isStatusTitle: { _ in false },
        command: { start, _ in ClaudeLaunch.command(start) },
        claim: nil,
        readTranscript: { TranscriptTail.read($0, after: $1, queue: $2) }
    )

    public static let codex = Self(
        agent: .codex,
        name: "Codex",
        glyph: "terminal",
        isOptIn: true,
        capabilities: [.conversation, .contextSize, .pullRequestLinks, .needsYou, .idleUnload, .worktrees, .remote],
        liveSource: .tabSignals,
        readLive: CodexLive.sessions,
        isStatusTitle: { CodexRunState(title: $0) != nil },
        command: CodexLaunch.command,
        claim: { CodexLaunch.claim(for: $0, cwd: $1, in: $2, excluding: $3) },
        readTranscript: { CodexTranscript.read($0, after: $1, queue: $2) }
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
