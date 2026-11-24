import BerthCore
import Foundation
import Testing

struct UsageGroupsTests {
    @Test func decodedCodexUsageKeepsExpiredWindowsAndMarksStaleData() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = now.addingTimeInterval(-60)
        let windows = [
            UsageWindow(id: "session", title: "Session", length: 5 * 3600, used: 0.42, resetsAt: expired),
            UsageWindow(id: "week", title: "Week", length: 7 * 86_400, used: 0.31, resetsAt: expired),
            UsageWindow(id: "month", title: "30d", length: 30 * 86_400, used: 0.84, resetsAt: expired),
        ]
        let usage = PlanUsage(windows: windows)
        let original = CodexUsage(usage: usage, recordedAt: now.addingTimeInterval(-2 * 3600))
        let data = try JSONEncoder().encode(RemoteServerMessage.codexUsage(original))
        let message = try JSONDecoder().decode(RemoteServerMessage.self, from: data)
        guard case let .codexUsage(payload) = message else {
            Issue.record("Expected a Codex usage message")
            return
        }

        let decoded = try #require(payload)
        let groups = UsageGroup.groups(claude: nil, codex: decoded, at: now)
        #expect(groups == UsageGroup.groups(claude: nil, codex: original, at: now))
        #expect(groups.map(\.kind) == [.codex])
        let group = try #require(groups.first)
        #expect(group.staleSince == original.recordedAt)
        #expect(group.windows.map(\.id) == windows.map(\.id))
        #expect(group.windows.allSatisfy { $0.used == 0 && $0.resetsAt == nil })

        let fresh = CodexUsage(usage: usage, recordedAt: now.addingTimeInterval(-60))
        let freshGroups = UsageGroup.groups(claude: usage, codex: fresh, at: now)
        #expect(freshGroups.map(\.kind) == [.claude, .codex])
        #expect(freshGroups.allSatisfy { $0.staleSince == nil })
        #expect(UsageGroup.groups(claude: PlanUsage(windows: []), codex: CodexUsage(usage: PlanUsage(windows: []), recordedAt: now), at: now).isEmpty)
    }
}
