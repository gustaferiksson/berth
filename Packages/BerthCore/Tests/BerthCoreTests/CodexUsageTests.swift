import BerthCore
import Foundation
import Testing

struct CodexUsageTests {
    private func rollout(_ lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let directory = root.appending(path: "sessions/2026/01/02")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: directory.appending(path: "rollout-2026-01-02T03-04-05-\(UUID().uuidString.lowercased()).jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    private func record(at timestamp: String, primary: String, secondary: String) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":\#(primary),"secondary":\#(secondary)}}}"#
    }

    @Test func newestRecordMapsWindowsByLength() throws {
        let root = try rollout([
            record(at: "2026-01-02T03:00:00.000Z", primary: #"{"used_percent":5,"window_minutes":300,"resets_at":1767325200}"#, secondary: #"{"used_percent":10,"window_minutes":10080,"resets_at":1767800000}"#),
            #"{"timestamp":"2026-01-02T03:30:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
            record(at: "2026-01-02T04:00:00.000Z", primary: #"{"used_percent":9.0,"window_minutes":300,"resets_in_seconds":7200}"#, secondary: #"{"used_percent":29.0,"window_minutes":10080,"resets_at":1767800000}"#),
        ])
        let usage = try #require(CodexUsage.latest(in: root))
        #expect(usage.recordedAt == Date(timeIntervalSince1970: 1_767_326_400))
        #expect(usage.usage.windows.map(\.title) == ["Session", "Week"])
        #expect(usage.usage.windows.map(\.usedPercent) == [9, 29])
        #expect(usage.usage.windows[0].resetsAt == usage.recordedAt.addingTimeInterval(7200))
        #expect(!usage.isStale(at: usage.recordedAt.addingTimeInterval(60)))
        #expect(usage.isStale(at: usage.recordedAt.addingTimeInterval(2 * 3600)))
    }

    @Test func unusualWindowLengthsAreLabelledByLength() throws {
        let root = try rollout([record(at: "2026-01-02T04:00:00.000Z", primary: #"{"used_percent":1,"window_minutes":120,"resets_at":1767400000}"#, secondary: #"{"used_percent":2,"window_minutes":43200,"resets_at":1767900000}"#)])
        #expect(try #require(CodexUsage.latest(in: root)).usage.windows.map(\.title) == ["2h", "30d"])
    }

    @Test func rolloutsWithoutRateLimitsGiveNothing() throws {
        let root = try rollout([#"{"timestamp":"2026-01-02T04:00:00.000Z","type":"event_msg","payload":{"type":"agent_message"}}"#])
        #expect(CodexUsage.latest(in: root) == nil)
    }
}
