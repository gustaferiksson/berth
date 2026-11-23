@testable import BerthCore
import Foundation
import Testing

struct TranscriptWatchTests {
    private let date = try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-01T10:00:00.000Z")
    private let live = LiveSession(pid: 12, sessionId: "fixture", cwd: "/", status: "idle", startedAt: 1_793_523_600_000)
    private let scheduled = [
        #"{"type":"assistant","timestamp":"2026-11-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"cron","name":"CronCreate","input":{"prompt":"/steward --tend 123","cron":"*/5 * * * *"}}]}}"#,
        #"{"type":"user","timestamp":"2026-11-01T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"cron","content":"Scheduled the job"}]},"toolUseResult":{"jobId":"watch-1"}}"#,
    ]

    @Test(arguments: [false, true]) func shipStartsAWatchWithoutAPullRequestNumber(watchOnly: Bool) {
        var activity = TranscriptActivity(watchOnly: watchOnly)
        activity.apply(records([command("/ship")]))
        #expect(activity.pullRequestWatch(of: live, now: date) == PullRequestWatch(number: nil, since: date))
    }

    @Test(arguments: ["123", "https://github.com/acme/api/pull/123"]) func stewardReadsTheNumberOrURL(_ argument: String) {
        var activity = TranscriptActivity(watchOnly: true)
        activity.apply(records([command("/steward", argument: argument)]))
        let watch = activity.pullRequestWatch(of: live, now: date)
        #expect(watch?.number == 123)
        #expect(watch?.repository == (argument == "123" ? nil : "acme/api"))
    }

    @Test(arguments: ["/ship stop", "/steward stop", "/clear", "/resume", "/cd"]) func commandsEndTheWatch(_ stop: String) {
        var activity = TranscriptActivity(watchOnly: true)
        activity.apply(records([command("/steward", argument: "123")] + scheduled))
        #expect(activity.pullRequestWatch(of: live, now: date + 3)?.number == 123)
        let words = stop.split(separator: " ")
        activity.apply(records([command(String(words[0]), argument: words.dropFirst().first.map(String.init) ?? "", at: date + 5)]))
        #expect(activity.pullRequestWatch(of: live, now: date + 6) == nil)
    }

    @Test(arguments: [false, true]) func successfulCronIsWatchingAndExcludedFromTasks(watchOnly: Bool) {
        var activity = TranscriptActivity(watchOnly: watchOnly)
        activity.apply(records(Array(scheduled.prefix(1))))
        #expect(activity.pullRequestWatch(of: live, now: date + 2) == nil)
        activity.apply(records(Array(scheduled.suffix(1))))
        #expect(activity.pullRequestWatch(of: live, now: date + 3)?.number == 123)
        #expect(activity.tasks(of: live, now: date + 3) { _ in false }.isEmpty)
        activity.apply(records([#"{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-11-01T10:00:05.000Z","message":{"content":"<task-notification><task-id>watch-1</task-id><status>running</status></task-notification>"}}"#]))
        #expect(activity.pullRequestWatch(of: live, now: date + 5)?.number == 123)
        activity.apply(records([#"{"type":"user","origin":{"kind":"task-notification"},"timestamp":"2026-11-01T10:00:06.000Z","message":{"content":"<task-notification><task-id>watch-1</task-id><status>stopped</status></task-notification>"}}"#]))
        #expect(activity.pullRequestWatch(of: live, now: date + 6) == nil)
    }

    @Test func compactionKeepsTheWatchAndExpiryUsesTheCommandDate() {
        var activity = TranscriptActivity(watchOnly: true)
        activity.apply(records([command("/steward", argument: "123")] + scheduled + [
            #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-01T10:00:04.000Z"}"#,
        ]))
        let expiry = date + 7 * 86_400
        #expect(activity.pullRequestWatch(of: live, now: expiry - 1)?.number == 123)
        #expect(activity.pullRequestWatch(of: live, now: expiry) == nil)
    }

    @Test func noticesAndCheckoutChangesEndTheWatch() {
        var activity = TranscriptActivity(watchOnly: true)
        activity.apply(records([command("/steward", argument: "123"), #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:00:02.000Z","content":"<task-notification><summary>PR #321 was merged</summary></task-notification>"}"#]))
        #expect(activity.pullRequestWatch(of: live, now: date + 2)?.number == 123)
        activity.apply(records([#"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:00:03.000Z","content":"<task-notification><summary>PR #123 was closed</summary></task-notification>"}"#]))
        #expect(activity.pullRequestWatch(of: live, now: date + 3) == nil)
        activity.apply(records([command("/ship", at: date + 4), #"{"type":"user","gitBranch":"main","timestamp":"2026-11-01T10:00:05.000Z","message":{"content":"Continue"}}"#]))
        #expect(activity.pullRequestWatch(of: live, now: date + 5) == nil)
    }

    @Test func interruptedAndExitedSessionsAreNotWatching() {
        var activity = TranscriptActivity(watchOnly: true)
        activity.apply(records([command("/ship")]))
        let resumed = LiveSession(pid: 13, sessionId: "fixture", cwd: "/", status: "idle", startedAt: (date + 1).timeIntervalSince1970 * 1000)
        #expect(activity.pullRequestWatch(of: nil, now: date + 1) == nil)
        #expect(activity.pullRequestWatch(of: resumed, now: date + 1) == nil)
        activity.apply(records([#"{"type":"user","timestamp":"2026-11-01T10:00:02.000Z","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#]))
        #expect(activity.pullRequestWatch(of: live, now: date + 2) == nil)
    }

    @Test func ordinaryMentionsAndTendTicksDoNotStartAWatch() {
        var activity = TranscriptActivity(watchOnly: true)
        activity.apply(records([
            #"{"type":"user","timestamp":"2026-11-01T10:00:00.000Z","message":{"content":"What do /ship and /steward do?"}}"#,
            command("/shipwreck"), command("/steward-example"), command("/steward", argument: "--tend 123"),
        ]))
        #expect(activity.pullRequestWatch(of: live, now: date) == nil)
    }

    @Test func virtualSchedulesEndWhenDeleted() {
        var activity = TranscriptActivity(watchOnly: true)
        activity.apply(records([
            #"{"type":"user","isVirtual":true,"timestamp":"2026-11-01T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"repl_1"}]},"toolUseResult":{"taskId":"watch-1","description":"/steward --tend 123"}}"#,
        ]))
        #expect(activity.pullRequestWatch(of: live, now: date + 1)?.number == 123)
        activity.apply(records([
            #"{"type":"assistant","timestamp":"2026-11-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"delete","name":"CronDelete","input":{"id":"watch-1"}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"delete"}]}}"#,
        ]))
        #expect(activity.pullRequestWatch(of: live, now: date + 3) == nil)
    }

    @Test func theRemoteFieldDecodesWhenPresentOrOmitted() throws {
        let base = #"{"id":"fixture","title":"Watch the export","folder":"/garden","lastActivity":0,"isOpen":true,"isLocked":false"#
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(RemoteSession.self, from: Data((base + "}").utf8))
        let current = try decoder.decode(RemoteSession.self, from: Data((base + #","pullRequestWatch":{"number":123,"repository":"acme/api","since":0}}"#).utf8))
        #expect(legacy.pullRequestWatch == nil)
        #expect(current.pullRequestWatch?.number == 123)
        #expect(try decoder.decode(RemoteSession.self, from: JSONEncoder().encode(current)) == current)
    }

    private func command(_ name: String, argument: String = "", at time: Date? = nil) -> String {
        let timestamp = (time ?? date).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return #"{"type":"user","gitBranch":"feature","timestamp":"\#(timestamp)","message":{"content":"<command-name>\#(name)</command-name>\n<command-message>\#(name)</command-message>\n<command-args>\#(argument)</command-args>"}}"#
    }

    private func records(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}
