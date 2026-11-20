@testable import BerthCore
import Foundation
import Testing

struct TaskDetailTests {
    private let live = try! JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":1,"sessionId":"s","cwd":"/","status":"busy","startedAt":1793523600000}"#.utf8))
    private let now = try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-01T10:03:00.000Z")
    private let launches = [
        #"{"type":"assistant","timestamp":"2026-11-01T10:00:00.000Z","message":{"model":"m","content":[{"type":"tool_use","id":"tu-shell","name":"Bash","input":{"command":"npm run dev","description":"Start the dev server","run_in_background":true}}]}}"#,
        #"{"type":"user","timestamp":"2026-11-01T10:00:01.000Z","message":{"content":[{"tool_use_id":"tu-shell","type":"tool_result","content":"Command running in background with ID: bshell1. Output is being written to: /tmp/claude-fixture/tasks/bshell1.output"}]},"toolUseResult":{"backgroundTaskId":"bshell1"}}"#,
        #"{"type":"assistant","timestamp":"2026-11-01T10:01:00.000Z","message":{"model":"m","content":[{"type":"tool_use","id":"tu-agent","name":"Agent","input":{"description":"Find the auth middleware","subagent_type":"Explore","prompt":"x"}}]}}"#,
        #"{"type":"user","timestamp":"2026-11-01T10:01:01.000Z","message":{"content":[{"tool_use_id":"tu-agent","type":"tool_result","content":"Async agent launched."}]},"toolUseResult":{"isAsync":true,"agentId":"agent1"}}"#,
    ]

    private func activity(_ lines: [String]) -> TranscriptActivity {
        var activity = TranscriptActivity()
        activity.apply(Data((lines.joined(separator: "\n") + "\n").utf8))
        return activity
    }

    @Test func shellsCarryTheirCommandAndOutputFile() {
        let parsed = activity(launches)
        let shell = parsed.tasks(of: live, now: now) { _ in false }.first { $0.id == "bshell1" }
        #expect(shell?.command == "npm run dev")
        #expect(shell?.title == "Start the dev server")
        #expect(parsed.outputFile(of: "bshell1")?.path == "/tmp/claude-fixture/tasks/bshell1.output")
        #expect(parsed.outputFile(of: "agent1") == nil)
    }

    @Test func anOutputFileNamedAfterAnotherTaskIsRefused() {
        let forged = launches[1].replacing("bshell1.output", with: "../../etc/passwd")
        #expect(activity([launches[0], forged]).outputFile(of: "bshell1") == nil)
    }

    @Test func agentsCarryTheirTypeAndProgress() {
        var log = AgentLog()
        log.apply(Data((AgentLogTests.lines.joined(separator: "\n") + "\n").utf8))
        let agent = activity(launches).tasks(of: live, now: now, progress: ["agent1": log]) { _ in false }.first { $0.id == "agent1" }
        #expect(agent?.agentType == "Explore")
        #expect(agent?.toolCount == 3)
        #expect(agent?.tokens == 1300)
        #expect(agent?.call == RemoteToolCall(name: "Read", summary: "/src/auth.ts", date: agent?.call?.date))
        #expect(agent?.call?.phrase == "Reading /src/auth.ts")
    }

    @Test func tasksFromAnOlderMacDecode() throws {
        let task = try JSONDecoder().decode(RemoteTask.self, from: Data(#"{"id":"b","kind":"shell","title":"t","started":0}"#.utf8))
        #expect(task.command == nil && task.call == nil && task.toolCount == nil)
    }
}

struct AgentLogTests {
    static let lines = [
        #"{"type":"user","isSidechain":true,"timestamp":"2026-11-01T10:01:02.000Z","message":{"content":"Find the auth middleware"}}"#,
        #"{"type":"assistant","isSidechain":true,"timestamp":"2026-11-01T10:01:03.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"authenticate"}},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"ls src\nls lib","description":"List sources"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":40}}}"#,
        #"{"type":"user","isSidechain":true,"timestamp":"2026-11-01T10:01:04.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}"#,
        #"{"type":"assistant","isSidechain":true,"timestamp":"2026-11-01T10:01:05.000Z","message":{"id":"m2","content":[{"type":"tool_use","id":"t3","name":"Read","input":{"file_path":"/src/auth.ts"}}],"usage":{"input_tokens":12,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":88}}}"#,
    ]

    @Test func countsToolUsesAndTakesTheLatestUsage() {
        var log = AgentLog()
        log.apply(Data((Self.lines.joined(separator: "\n") + "\n").utf8))
        #expect(log.toolCount == 3)
        #expect(log.tokens == 1300)
        #expect(log.calls.map(\.name) == ["Grep", "Bash", "Read"])
        #expect(log.calls.map(\.summary) == ["authenticate", "List sources", "/src/auth.ts"])
    }

    @Test func readsAppendedBytesOnceAndKeepsAPartialLine() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }

        try (Self.lines[1] + "\n" + String(Self.lines[3].prefix(40))).write(to: file, atomically: true, encoding: .utf8)
        var log = AgentLog()
        log.read(file)
        #expect(log.toolCount == 2)

        try (Self.lines[1] + "\n" + Self.lines[3] + "\n").write(to: file, atomically: true, encoding: .utf8)
        log.read(file)
        log.read(file)
        #expect(log.toolCount == 3)
    }

    @Test func keepsOnlyTheRecentCalls() {
        let many = (0..<30).map { #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t\#($0)","name":"Read","input":{"file_path":"/f\#($0)"}}]}}"# }
        var log = AgentLog()
        log.apply(Data((many.joined(separator: "\n") + "\n").utf8))
        #expect(log.toolCount == 30)
        #expect(log.calls.count == 20)
        #expect(log.calls.last?.summary == "/f29")
    }
}

struct TaskOutputTests {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "out-\(UUID().uuidString).output")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func returnsTheLastLinesWithoutColourCodes() throws {
        let url = try file((1...100).map { "\u{1B}[32mline \($0)\u{1B}[0m" }.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = try #require(TaskOutput.tail(url, maxLines: 50)).split(separator: "\n")
        #expect(lines.count == 50)
        #expect(lines.first == "line 51" && lines.last == "line 100")
    }

    @Test func dropsTheLineACapCutsInHalf() throws {
        let url = try file("first line\nsecond line\nthird line\n")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(TaskOutput.tail(url, maxBytes: 20) == "third line")
        #expect(TaskOutput.tail(url.appending(path: "missing")) == nil)
    }
}
