import Foundation

public nonisolated struct UsageGroup: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case claude = "Claude"
        case codex = "Codex"
    }

    public let kind: Kind
    public let windows: [UsageWindow]
    public let staleSince: Date?

    public var id: Kind { kind }
    public var name: String { kind.rawValue }

    public static func groups(claude: PlanUsage?, codex: CodexUsage?, at now: Date) -> [Self] {
        let claudeGroup = claude.map { Self(kind: .claude, windows: $0.current(at: now), staleSince: nil) }
        let codexGroup = codex.map { usage in
            Self(kind: .codex, windows: usage.usage.current(at: now), staleSince: usage.isStale(at: now) ? usage.recordedAt : nil)
        }
        return [claudeGroup, codexGroup].compactMap(\.self).filter { !$0.windows.isEmpty }
    }
}
