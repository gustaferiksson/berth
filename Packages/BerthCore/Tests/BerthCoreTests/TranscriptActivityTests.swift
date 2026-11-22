@testable import BerthCore
import Foundation
import Testing

struct TranscriptActivityTests {
    private let launches = [
        #"{"type":"assistant","timestamp":"2026-11-01T10:00:00.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-shell","name":"Bash","input":{"command":"npm run dev","description":"Start the dev server","run_in_background":true}}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":90,"output_tokens":5}}}"#,
        #"{"type":"user","timestamp":"2026-11-01T10:00:01.000Z","message":{"content":[{"tool_use_id":"tu-shell","type":"tool_result","content":"Command running in background with ID: bshell1."}]},"toolUseResult":{"stdout":"","backgroundTaskId":"bshell1"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-01T10:01:00.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-agent","name":"Agent","input":{"description":"Review the parser","prompt":"…"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":5}}}"#,
        #"{"type":"user","timestamp":"2026-11-01T10:01:01.000Z","message":{"content":[{"tool_use_id":"tu-agent","type":"tool_result","content":"Async agent launched successfully."}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agent1"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-01T10:02:00.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-monitor","name":"Monitor","input":{"description":"Watch CI","command":"gh run watch","timeout_ms":600000}}],"usage":{"input_tokens":10,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0,"output_tokens":5}}}"#,
        #"{"type":"user","timestamp":"2026-11-01T10:02:01.000Z","message":{"content":[{"tool_use_id":"tu-monitor","type":"tool_result","content":"Monitor started."}]},"toolUseResult":{"taskId":"bmon1","timeoutMs":600000,"persistent":false}}"#,
    ]
    private let live = try! JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":1,"sessionId":"s","cwd":"/","status":"busy","startedAt":1793523600000}"#.utf8))
    private let now = try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-01T10:03:00.000Z")

    private func activity(_ lines: [String]) -> TranscriptActivity {
        var activity = TranscriptActivity()
        activity.apply(Data((lines.joined(separator: "\n") + "\n").utf8))
        return activity
    }

    private func session(_ status: String, startedAt: String = "1793523600000") -> LiveSession {
        try! JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":1,"sessionId":"s","cwd":"/","status":"\#(status)","startedAt":\#(startedAt)}"#.utf8))
    }

    @Test func launchesShellsAgentsAndMonitorsInTheBackground() {
        let tasks = activity(launches).tasks(of: live, now: now) { _ in false }
        #expect(tasks.map(\.id) == ["bshell1", "agent1", "bmon1"])
        #expect(tasks.map(\.kind) == [RemoteTask.shell, RemoteTask.agent, RemoteTask.monitor])
        #expect(tasks.map(\.title) == ["Start the dev server", "Review the parser", "Watch CI"])
    }

    @Test func stoppedAgentCountsAgainOnceItsLogGrowsPastTheMeta() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let subagents = folder.appending(path: "s/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let transcript = folder.appending(path: "s.jsonl")
        try Data((launches.joined(separator: "\n") + "\n").utf8).write(to: transcript)
        let meta = subagents.appending(path: "agent-agent1.meta.json")
        let log = subagents.appending(path: "agent-agent1.jsonl")
        try Data(#"{"stoppedByUser":true}"#.utf8).write(to: meta)
        try Data("{}\n".utf8).write(to: log)
        let stoppedAt = Date.now
        try FileManager.default.setAttributes([.modificationDate: stoppedAt], ofItemAtPath: meta.path)
        try FileManager.default.setAttributes([.modificationDate: stoppedAt - 1], ofItemAtPath: log.path)
        let catalogs = folder.appending(path: "catalogs")

        let stopped = TranscriptActivity.report(transcript, previous: TranscriptActivity(), logs: [:], live: live, catalogDirectory: catalogs)
        #expect(!stopped.report.tasks.map(\.id).contains("agent1"))

        try FileManager.default.setAttributes([.modificationDate: stoppedAt + 60], ofItemAtPath: log.path)
        let resumed = TranscriptActivity.report(transcript, previous: TranscriptActivity(), logs: [:], live: live, catalogDirectory: catalogs)
        #expect(resumed.report.tasks.map(\.id).contains("agent1"))
    }

    @Test func launchesFromReplScriptsCountAndEndLikeDirectTools() {
        let lines = [
            #"{"type":"user","timestamp":"2026-11-01T10:00:01.000Z","isVirtual":true,"turnCompanion":true,"message":{"content":[{"tool_use_id":"repl_1","type":"tool_result","content":""}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agent1","description":"Review the parser"}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:00:02.000Z","isVirtual":true,"turnCompanion":true,"message":{"content":[{"tool_use_id":"repl_2","type":"tool_result","content":""}]},"toolUseResult":{"backgroundTaskId":"bshell1","description":"Start the dev server"}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:00:03.000Z","isVirtual":true,"turnCompanion":true,"message":{"content":[{"tool_use_id":"repl_3","type":"tool_result","content":""}]},"toolUseResult":{"taskId":"bmon1","timeoutMs":600000,"persistent":true,"description":"Watch CI"}}"#,
        ]
        let all = activity(lines)
        let tasks = all.tasks(of: live, now: now) { _ in false }
        #expect(tasks.map(\.id) == ["agent1", "bshell1", "bmon1"])
        #expect(tasks.map(\.kind) == [RemoteTask.agent, RemoteTask.shell, RemoteTask.monitor])
        #expect(tasks.map(\.title) == ["Review the parser", "Start the dev server", "Watch CI"])
        #expect(all.tasks(of: session("busy", startedAt: "1793527290000"), now: now) { _ in false }.isEmpty)
        #expect(all.tasks(of: live, now: now) { $0 == "agent1" }.map(\.id) == ["bshell1", "bmon1"])

        let ended = activity(lines + [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:00.000Z","content":"<task-notification>\n<task-id>bshell1</task-id>\n<tool-use-id>repl_2</tool-use-id>\n<status>completed</status>\n</task-notification>"}"#,
        ])
        #expect(ended.tasks(of: live, now: now) { _ in false }.map(\.id) == ["agent1", "bmon1"])
    }

    @Test func notificationsEndTasksInEveryCarrier() {
        let ended = activity(launches + [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:10.000Z","content":"<task-notification>\n<task-id>bshell1</task-id>\n<status>completed</status>\n<summary>done</summary>\n</task-notification>"}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:02:20.000Z","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>\n<task-id>agent1</task-id>\n<status>failed</status>\n</task-notification>"}}"#,
            #"{"type":"attachment","timestamp":"2026-11-01T10:02:30.000Z","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>bmon1</task-id>\n<status>stopped</status>\n</task-notification>"}}"#,
        ])
        #expect(ended.tasks(of: live, now: now) { _ in false }.isEmpty)
    }

    @Test func oneNotificationCanEndSeveralTasks() {
        let ended = activity(launches + [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:10.000Z","content":"<task-notification>\n<task-id>bshell1</task-id>\n<task-id>agent1</task-id>\n<status>failed</status>\n</task-notification>"}"#,
        ])
        #expect(ended.tasks(of: live, now: now) { _ in false }.map(\.id) == ["bmon1"])
    }

    @Test func ignoresNotificationTextOutsideItsCarriers() {
        let quoted = activity(launches + [
            #"{"type":"user","timestamp":"2026-11-01T10:02:10.000Z","message":{"content":[{"tool_use_id":"tu-other","type":"tool_result","content":"<task-notification><task-id>bshell1</task-id><status>completed</status></task-notification>"}]}}"#,
            #"{"type":"queue-operation","operation":"remove","timestamp":"2026-11-01T10:02:11.000Z","content":"<task-notification><task-id>agent1</task-id><status>completed</status></task-notification>"}"#,
        ])
        #expect(quoted.tasks(of: live, now: now) { _ in false }.count == 3)
    }

    @Test func taskStopKillsWithoutANotification() {
        let stopped = activity(launches + [
            #"{"type":"assistant","timestamp":"2026-11-01T10:02:30.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-stop","name":"TaskStop","input":{"task_id":"bshell1"}}],"usage":{"input_tokens":1}}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:02:31.000Z","message":{"content":[{"tool_use_id":"tu-stop","type":"tool_result","content":"Stopped"}]},"toolUseResult":{"message":"Successfully stopped task: bshell1","task_id":"bshell1","task_type":"local_bash"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T10:02:40.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-stop2","name":"TaskStop","input":{"task_id":"agent1"}}],"usage":{"input_tokens":1}}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:02:41.000Z","message":{"content":[{"tool_use_id":"tu-stop2","type":"tool_result","content":"No task found","is_error":true}]},"toolUseResult":"Error: No task found"}"#,
        ])
        #expect(stopped.tasks(of: live, now: now) { _ in false }.map(\.id) == ["agent1", "bmon1"])
    }

    @Test func monitorsEndWhenTheyExpire() {
        let events = activity(launches + [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:20.000Z","content":"<task-notification>\n<task-id>bmon1</task-id>\n<summary>Monitor event</summary>\n<event>new comment</event>\n</task-notification>"}"#,
        ])
        #expect(events.tasks(of: live, now: now) { _ in false }.map(\.id).contains("bmon1"))
        #expect(!events.tasks(of: live, now: now + 600) { _ in false }.map(\.id).contains("bmon1"))

        let expired = activity(launches + [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:20.000Z","content":"<task-notification>\n<task-id>bmon1</task-id>\n<event>[Monitor expired after 10m with no events delivered.]</event>\n</task-notification>"}"#,
        ])
        #expect(!expired.tasks(of: live, now: now) { _ in false }.map(\.id).contains("bmon1"))
    }

    @Test func resumedAgentsRunAgainUntilTheirNextNotification() {
        let resumed = activity(launches + [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:10.000Z","content":"<task-notification><task-id>agent1</task-id><status>completed</status></task-notification>"}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T10:02:20.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-send","name":"SendMessage","input":{"to":"agent1","summary":"One more fix","message":"…"}}],"usage":{"input_tokens":1}}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:02:21.000Z","message":{"content":[{"tool_use_id":"tu-send","type":"tool_result","content":"Resumed"}]},"toolUseResult":{"success":true,"message":"Resumed","resumedAgentId":"agent1"}}"#,
        ])
        #expect(resumed.tasks(of: live, now: now) { _ in false }.first { $0.id == "agent1" }?.title == "Review the parser")

        let finished = activity(launches + [
            #"{"type":"assistant","timestamp":"2026-11-01T10:02:20.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-send","name":"SendMessage","input":{"to":"agent1","summary":"One more fix"}}],"usage":{"input_tokens":1}}}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:20.500Z","content":"<task-notification><task-id>agent1</task-id><status>completed</status></task-notification>"}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:02:21.000Z","message":{"content":[{"tool_use_id":"tu-send","type":"tool_result","content":"Resumed"}]},"toolUseResult":{"success":true,"resumedAgentId":"agent1"}}"#,
        ])
        #expect(!finished.tasks(of: live, now: now) { _ in false }.map(\.id).contains("agent1"))
    }

    @Test func resumesFromReplScriptsRunAgainUntilTheirNextNotification() {
        let launched = [
            #"{"type":"user","timestamp":"2026-11-01T10:00:01.000Z","isVirtual":true,"turnCompanion":true,"message":{"content":[{"tool_use_id":"repl_1","type":"tool_result","content":""}]},"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agent1","description":"Review the parser"}}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:01:00.000Z","content":"<task-notification>\n<task-id>agent1</task-id>\n<tool-use-id>repl_1</tool-use-id>\n<status>completed</status>\n</task-notification>"}"#,
        ]
        let resume = #"{"type":"user","timestamp":"2026-11-01T10:02:00.000Z","isVirtual":true,"turnCompanion":true,"message":{"content":[{"tool_use_id":"repl_2","type":"tool_result","content":""}]},"toolUseResult":{"success":true,"message":"Resuming agent agent1","resumedAgentId":"agent1","revivedAgentId":"agent1"}}"#
        let resumed = activity(launched + [resume])
        #expect(resumed.tasks(of: live, now: now) { _ in false }.map(\.title) == ["Review the parser"])

        let finished = activity(launched + [
            resume,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:02:30.000Z","content":"<task-notification>\n<task-id>agent1</task-id>\n<tool-use-id>repl_2</tool-use-id>\n<status>completed</status>\n</task-notification>"}"#,
        ])
        #expect(finished.tasks(of: live, now: now) { _ in false }.isEmpty)
    }

    @Test func foregroundAgentsRunUntilTheirResultWhileTheSessionWorks() {
        let call = #"{"type":"assistant","timestamp":"2026-11-01T10:02:30.000Z","message":{"model":"claude-test-1","content":[{"type":"tool_use","id":"tu-fg","name":"Agent","input":{"description":"Explore the code"}}],"usage":{"input_tokens":1}}}"#
        let pending = activity([call])
        #expect(pending.tasks(of: session("busy"), now: now) { _ in false }.map(\.id) == ["tu-fg"])
        #expect(pending.tasks(of: session("idle"), now: now) { _ in false }.isEmpty)

        let interrupted = activity([call, #"{"type":"user","timestamp":"2026-11-01T10:02:40.000Z","message":{"content":[{"tool_use_id":"tu-fg","type":"tool_result","content":"[Request interrupted by user for tool use]","is_error":true}]},"toolUseResult":"Error: interrupted"}"#])
        #expect(interrupted.tasks(of: session("busy"), now: now) { _ in false }.isEmpty)
    }

    @Test func nothingRunsOutsideTheLiveProcess() {
        let all = activity(launches)
        #expect(all.tasks(of: nil, now: now) { _ in false }.isEmpty)
        #expect(all.tasks(of: session("busy", startedAt: "1793527290000"), now: now) { _ in false }.map(\.id) == ["bmon1"])
        #expect(all.tasks(of: session("idle"), now: now) { _ in false }.map(\.id) == ["agent1", "bmon1"])
        #expect(all.tasks(of: live, now: now) { $0 == "agent1" }.map(\.id) == ["bshell1", "bmon1"])
    }

    @Test func readsIncrementallyAcrossPartialLines() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = launches.joined(separator: "\n") + "\n"
        let split = text.index(text.startIndex, offsetBy: launches[0].count + 40)
        try Data(text[..<split].utf8).write(to: url)

        var activity = TranscriptActivity()
        activity.read(url)
        #expect(activity.tasks(of: live, now: now) { _ in false }.isEmpty)
        #expect(activity.end == launches[0].utf8.count + 1)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text[split...].utf8))
        try handle.close()
        activity.read(url)
        #expect(activity.tasks(of: live, now: now) { _ in false }.map(\.id) == ["bshell1", "agent1", "bmon1"])
        #expect(activity.end == text.utf8.count)
    }

    @Test func contextIsTheLastMainReplysPromptSize() throws {
        let catalog = Data(#"{"fetchedAt":2,"catalog":{"config":{"models":[{"id":"claude-test-1","runtime":{"max_input_tokens":4000}}]}}}"#.utf8)
        let stale = Data(#"{"fetchedAt":1,"catalog":{"config":{"models":[{"id":"claude-test-1","name":"Test 1","runtime":{"max_input_tokens":9000}}]}}}"#.utf8)
        #expect(TranscriptActivity.catalogModel("claude-test-1", catalogs: [stale, catalog]) == (4000, "Test 1"))
        #expect(TranscriptActivity.catalogModel("claude-other", catalogs: [catalog]) == (nil, nil))

        let replies = activity(launches + [
            #"{"type":"assistant","isSidechain":true,"timestamp":"2026-11-01T10:02:50.000Z","message":{"model":"claude-test-1","content":[],"usage":{"input_tokens":99999}}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-01T10:02:55.000Z","message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":0}}}"#,
        ])
        let context = try #require(replies.context(window: 4000))
        #expect(context.model == "claude-test-1" && context.tokens == 3010 && context.window == 4000 && context.compactions == 0)
        #expect(replies.context(window: 3000)?.window == nil)
    }

    @Test func compactionHidesTheSizeUntilTheNextReply() {
        let boundary = #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-01T10:05:00.000Z","compactMetadata":{"trigger":"auto","preTokens":3010,"postTokens":200}}"#
        let compacted = activity(launches + [boundary])
        #expect(compacted.context(window: 4000)?.tokens == nil && compacted.context(window: 4000)?.compactions == 1)

        let next = activity(launches + [boundary, #"{"type":"assistant","timestamp":"2026-11-01T10:06:00.000Z","message":{"model":"claude-test-1","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":700}}}"#])
        #expect(next.context(window: 4000)?.tokens == 705 && next.context(window: 4000)?.lastCompaction != nil)
    }

    @Test func theScansTailContextMatchesTheActivitys() throws {
        let head = Transcript.records(in: Data(#"{"type":"user","cwd":"/x","timestamp":"2026-11-01T09:59:00.000Z","message":{"content":"start"}}"#.utf8), dropFirst: false, dropLast: false)
        let summary = { (lines: [String], earlier: SessionContext?) in
            Transcript.summary(id: "a", folder: "-x", modified: .now, head: head, tail: Transcript.records(in: Data(lines.joined(separator: "\n").utf8), dropFirst: false, dropLast: false), earlierContext: earlier)?.context
        }
        let sidechain = #"{"type":"assistant","isSidechain":true,"timestamp":"2026-11-01T10:02:50.000Z","message":{"model":"claude-test-1","content":[],"usage":{"input_tokens":99999}}}"#
        let synthetic = #"{"type":"assistant","timestamp":"2026-11-01T10:02:55.000Z","message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":0}}}"#
        let boundary = #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-01T10:05:00.000Z"}"#
        let reply = #"{"type":"assistant","timestamp":"2026-11-01T10:06:00.000Z","message":{"model":"claude-test-2","content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":700}}}"#

        for lines in [launches + [sidechain, synthetic], launches + [boundary, reply]] {
            let context = try #require(summary(lines, nil))
            #expect(context.model == activity(lines).model && context.tokens == activity(lines).context(window: nil)?.tokens)
        }
        #expect(summary(launches + [sidechain, synthetic], nil) == SessionContext(model: "claude-test-1", tokens: 3010))

        let earlier = SessionContext(model: "claude-test-1", tokens: 6)
        #expect(summary(launches + [boundary], earlier) == nil && activity(launches + [boundary]).context(window: nil)?.tokens == nil)
        #expect(summary([#"{"type":"ai-title","aiTitle":"Cards"}"#], earlier) == earlier)
    }

    @Test func transcriptMessagesDecodeWithAndWithoutActivity() throws {
        guard case let .transcript(_, _, _, _, missing) = try JSONDecoder().decode(RemoteServerMessage.self, from: Data(#"{"transcript":{"sessionID":"s","entries":[],"isContinuation":true,"queued":[]}}"#.utf8)) else { throw CancellationError() }

        #expect(missing == nil)

        let activity = RemoteActivity(tasks: [RemoteTask(id: "b1", kind: "future-kind", title: "t", started: .now)], context: nil)
        let data = try JSONEncoder().encode(RemoteServerMessage.transcript(sessionID: "s", entries: [], isContinuation: false, queued: nil, activity: activity))
        guard case let .transcript(_, _, _, _, decoded) = try JSONDecoder().decode(RemoteServerMessage.self, from: data) else { throw CancellationError() }

        #expect(decoded == activity)
    }
}
