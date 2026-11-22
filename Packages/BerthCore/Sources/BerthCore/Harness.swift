import Foundation

public enum Capability: String, CaseIterable, Sendable {
    case needsYou, approvals, modelEffortMenu, contextSize, pullRequestLinks, backgroundTasks, idleUnload, worktrees, remote, conversation
}

public enum LaunchStart: Sendable {
    case new, newInWorktree, resume, attach
}

public struct Harness: Sendable {
    public enum LiveSource: Sendable {
        case sessionFiles, notTracked
    }

    public typealias Claim = @Sendable (_ opened: Date, _ cwd: String, _ sessions: [SessionSummary], _ claimed: Set<String>) -> SessionSummary?
    public typealias ReadTranscript = @Sendable (_ url: URL, _ offset: Int?, _ queue: [String]) -> TranscriptTail.Chunk?

    public let agent: Agent
    public let name: String
    public let glyph: String
    public let isOptIn: Bool
    public let capabilities: Set<Capability>
    public let liveSource: LiveSource
    public let command: @Sendable (LaunchStart) -> String
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
        command: ClaudeLaunch.command,
        claim: nil,
        readTranscript: { TranscriptTail.read($0, after: $1, queue: $2) }
    )

    public static let codex = Self(
        agent: .codex,
        name: "Codex",
        glyph: "terminal",
        isOptIn: true,
        capabilities: [.conversation, .contextSize, .pullRequestLinks],
        liveSource: .notTracked,
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
