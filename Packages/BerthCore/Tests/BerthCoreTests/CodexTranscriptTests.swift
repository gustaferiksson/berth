@testable import BerthCore
import Foundation
import Testing

struct CodexTranscriptTests {
    private let timestamp = "2026-01-02T10:00:00.100Z"
    private var date: Date? { CodexRollout.date(timestamp) }

    private func line(_ payload: String, response: Bool = false) -> String {
        #"{"timestamp":"\#(timestamp)","type":"\#(response ? "response_item" : "event_msg")","payload":\#(payload)}"#
    }

    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "codex-transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func legacyEventsAndTools() throws {
        let url = try write([
            line(#"{"type":"user_message","id":"u","message":"Fix the fixture"}"#),
            line(#"{"type":"agent_message","id":"a","message":"Working"}"#),
            line(#"{"type":"function_call","name":"exec_command","call_id":"cmd","arguments":"{\"cmd\":\"echo sample\",\"workdir\":\"/work\",\"yield_time_ms\":1000}"}"#, response: true),
            line(#"{"type":"function_call_output","call_id":"cmd","output":"Chunk ID: x\nWall time: 1\nProcess exited with code 2\nOriginal token count: 1\nOutput:\nsample"}"#, response: true),
            line(#"{"type":"custom_tool_call","name":"exec","call_id":"code","input":"await tools.exec_command({cmd: \"echo \\\"one\\\"\"}); await tools.exec_command({cmd:\"echo two\"})"}"#, response: true),
            line(#"{"type":"custom_tool_call_output","call_id":"code","output":[{"type":"input_text","text":"Script completed\nWall time: 1\nOutput:"},{"type":"input_text","text":"one"},{"type":"input_text","text":"two"}]}"#, response: true),
            line(#"{"type":"patch_apply_end","call_id":"patch","success":true,"stdout":"ok","changes":{"/work/z":{"type":"add","content":"created"},"/work/a":{"type":"update","unified_diff":"@@ -1,2 +1,2 @@\n same\n-old\n+new\n\\ No newline at end of file","move_path":"/work/b"}}}"#),
            line(#"{"type":"web_search_end","call_id":"web","query":"fixture docs","results":[{"title":"Guide","url":"https://example.com"}]}"#),
            line(#"{"type":"function_call","name":"update_plan","call_id":"plan","arguments":"{\"explanation\":\"test\",\"plan\":[{\"step\":\"Check\",\"status\":\"pending\"}]}"}"#, response: true),
            line(#"{"type":"function_call_output","call_id":"plan","output":"Plan updated"}"#, response: true),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = try #require(CodexTranscript.read(url, after: nil, queue: ["queued"]))
        let expected = [
            RemoteEntry(id: "u", kind: .prompt, text: "Fix the fixture", date: date),
            RemoteEntry(id: "a", kind: .reply, text: "Working", date: date),
            RemoteEntry(id: "cmd", kind: .toolUse, text: #"{"command":"echo sample"}"#, toolID: "cmd", name: "Bash", command: "echo sample", date: date),
            RemoteEntry(id: "cmd", kind: .toolResult, text: "sample", toolID: "cmd", isError: true, date: date),
            RemoteEntry(id: "code", kind: .toolUse, text: #"{"command":"echo \"one\"\necho two"}"#, toolID: "code", name: "Bash", command: "echo \"one\"\necho two", date: date),
            RemoteEntry(id: "code", kind: .toolResult, text: "one\ntwo", toolID: "code", date: date),
            RemoteEntry(id: "patch-0", kind: .toolUse, text: "", toolID: "patch-0", name: "Edit", filePath: "/work/a", oldText: "same\nold", newText: "same\nnew", date: date, detail: "moved to /work/b"),
            RemoteEntry(id: "patch-0-result", kind: .toolResult, text: "ok", toolID: "patch-0", date: date),
            RemoteEntry(id: "patch-1", kind: .toolUse, text: "", toolID: "patch-1", name: "Write", filePath: "/work/z", newText: "created", date: date),
            RemoteEntry(id: "patch-1-result", kind: .toolResult, text: "ok", toolID: "patch-1", date: date),
            RemoteEntry(id: "web", kind: .toolUse, text: #"{"query":"fixture docs"}"#, toolID: "web", name: "WebSearch", date: date, detail: "fixture docs"),
            RemoteEntry(id: "web-result", kind: .toolResult, text: "Guide https://example.com", toolID: "web", date: date),
            RemoteEntry(id: "plan", kind: .toolUse, text: #"{"explanation":"test","plan":[{"step":"Check","status":"pending"}]}"#, toolID: "plan", name: "TodoWrite", date: date),
            RemoteEntry(id: "plan", kind: .toolResult, text: "Plan updated", toolID: "plan", date: date),
        ]
        #expect(chunk.entries == expected)
        #expect(chunk.queue == ["queued"])
        #expect(chunk.imageLines.isEmpty)
        #expect(chunk.isTurnOpen == nil)
        #expect(CodexTranscript.read(url, after: nil, queue: [])?.entries == expected)
        let turns = Turn.turns(from: chunk.entries)
        #expect(turns.count == 1)
        #expect(turns.first?.fileChanges?.files == 2)
        let calls = turns.flatMap(\.parts).flatMap { part -> [ToolCall] in
            switch part {
            case let .work(calls), let .cards(calls): calls
            case .reply: []
            }
        }
        #expect(calls.count == 6)
        #expect(calls.allSatisfy { $0.result != nil })
    }

    @Test func itemEraUsesOnlyItemCommandsAndFileChanges() throws {
        let url = try write([
            line(#"{"type":"item_completed","item":{"type":"UserMessage","id":"u","content":[{"type":"text","text":"First"},{"type":"text","text":"Second"}]}}"#),
            line(#"{"type":"item_completed","item":{"type":"AgentMessage","id":"a","content":[{"type":"text","text":"Ready"}],"phase":"commentary"}}"#),
            line(#"{"type":"function_call","name":"exec_command","call_id":"legacy","arguments":"{\"cmd\":\"ignored\"}"}"#, response: true),
            line(#"{"type":"function_call_output","call_id":"legacy","output":"ignored"}"#, response: true),
            line(#"{"type":"custom_tool_call","name":"exec","call_id":"legacy-code","input":"tools.exec_command({cmd:\"ignored\"})"}"#, response: true),
            line(#"{"type":"custom_tool_call_output","call_id":"legacy-code","output":"ignored"}"#, response: true),
            line(#"{"type":"item_completed","item":{"type":"CommandExecution","id":"ok","command":["zsh","-lc","echo ok"],"cwd":"/work","aggregated_output":"ok","exit_code":0,"status":"completed"}}"#),
            line(#"{"type":"item_completed","item":{"type":"CommandExecution","id":"bad","command":["false"],"aggregated_output":"failed","exit_code":1,"status":"failed"}}"#),
            line(#"{"type":"item_completed","item":{"type":"FileChange","id":"files","changes":{"/work/new":{"type":"add","content":"new"},"/work/old":{"type":"update","unified_diff":"@@ -1 +1 @@\n-before\n+after"}},"status":"completed","stdout":"saved"}}"#),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let chunk = try #require(CodexTranscript.read(url, after: nil, queue: []))
        #expect(chunk.entries == [
            RemoteEntry(id: "u", kind: .prompt, text: "First\nSecond", date: date),
            RemoteEntry(id: "a", kind: .reply, text: "Ready", date: date),
            RemoteEntry(id: "ok", kind: .toolUse, text: #"{"command":"echo ok"}"#, toolID: "ok", name: "Bash", command: "echo ok", date: date),
            RemoteEntry(id: "ok-result", kind: .toolResult, text: "ok", toolID: "ok", date: date),
            RemoteEntry(id: "bad", kind: .toolUse, text: #"{"command":"false"}"#, toolID: "bad", name: "Bash", command: "false", date: date),
            RemoteEntry(id: "bad-result", kind: .toolResult, text: "failed", toolID: "bad", isError: true, date: date),
            RemoteEntry(id: "files-0", kind: .toolUse, text: "", toolID: "files-0", name: "Write", filePath: "/work/new", newText: "new", date: date),
            RemoteEntry(id: "files-0-result", kind: .toolResult, text: "saved", toolID: "files-0", date: date),
            RemoteEntry(id: "files-1", kind: .toolUse, text: "", toolID: "files-1", name: "Edit", filePath: "/work/old", oldText: "before", newText: "after", date: date),
            RemoteEntry(id: "files-1-result", kind: .toolResult, text: "saved", toolID: "files-1", date: date),
        ])
        #expect(Turn.turns(from: chunk.entries).first?.fileChanges?.files == 2)
    }

    @Test func deduplicatesMessagesAndTracksTurnBoundariesAcrossReads() throws {
        let url = try write([
            line(#"{"type":"task_started"}"#),
            line(#"{"type":"user_message","message":"Hello"}"#),
            line(#"{"type":"item_completed","item":{"type":"UserMessage","id":"duplicate-u","content":[{"type":"text","text":"Hello"}]}}"#),
            line(#"{"type":"agent_message","id":"a","message":"Hi"}"#),
            line(#"{"type":"item_completed","item":{"type":"AgentMessage","id":"duplicate-a","content":[{"type":"text","text":"Hi"}]}}"#),
            line(#"{"type":"response_message","message":"ignored"}"#, response: true),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(CodexTranscript.read(url, after: nil, queue: []))
        #expect(first.isTurnOpen == true)
        #expect(first.entries == [RemoteEntry(id: "\(timestamp)-0", kind: .prompt, text: "Hello", date: date), RemoteEntry(id: "a", kind: .reply, text: "Hi", date: date)])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(#"{"type":"turn_aborted","reason":"interrupted"}"#) + "\n").utf8))
        let second = try #require(CodexTranscript.read(url, after: first.end, queue: ["next"]))
        #expect(second.isContinuation)
        #expect(second.queue == ["next"])
        #expect(second.isTurnOpen == false)
        #expect(second.entries == [RemoteEntry(id: "\(timestamp)-0", kind: .prompt, text: "[Request interrupted by user]", date: date)])
        #expect(Turn.turns(from: first.entries + second.entries).first?.isInterrupted == true)
        #expect(CodexTranscript.read(url, after: second.end, queue: [])?.isTurnOpen == nil)
        try handle.write(contentsOf: Data((line(#"{"type":"task_started"}"#) + "\n" + line(#"{"type":"task_complete"}"#) + "\n").utf8))
        #expect(CodexTranscript.read(url, after: second.end, queue: [])?.isTurnOpen == false)
    }

    @Test func scriptsSkippedCallsAndUnpairedContinuationResults() throws {
        let url = try write([
            line(#"{"type":"custom_tool_call","name":"exec","call_id":"patch-script","input":"tools.apply_patch(\"fixture\")"}"#, response: true),
            line(#"{"type":"custom_tool_call_output","call_id":"patch-script","output":[{"type":"input_text","text":"Script completed\nOutput:"},{"type":"input_text","text":"applied"}]}"#, response: true),
            line(#"{"type":"custom_tool_call","name":"exec","call_id":"script","input":"\nconst sample = 1;\ntext(sample)"}"#, response: true),
            line(#"{"type":"function_call","name":"wait","call_id":"wait","arguments":"{}"}"#, response: true),
            line(#"{"type":"function_call_output","call_id":"wait","output":"hidden"}"#, response: true),
            line(#"{"type":"function_call","name":"spawn_agent","call_id":"agent","arguments":"{\"message\":\"Inspect fixture\",\"count\":2}"}"#, response: true),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(CodexTranscript.read(url, after: nil, queue: []))
        #expect(first.entries == [
            RemoteEntry(id: "patch-script", kind: .toolUse, text: "tools.apply_patch(\"fixture\")", toolID: "patch-script", name: "Script", date: date, detail: "apply_patch"),
            RemoteEntry(id: "patch-script", kind: .toolResult, text: "applied", toolID: "patch-script", date: date),
            RemoteEntry(id: "script", kind: .toolUse, text: "\nconst sample = 1;\ntext(sample)", toolID: "script", name: "Script", date: date, detail: "const sample = 1;"),
            RemoteEntry(id: "agent", kind: .toolUse, text: #"{"subagent_type":"Agent"}"#, toolID: "agent", name: "Agent", date: date, detail: "Inspect fixture"),
        ])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let output = line(#"{"type":"function_call_output","call_id":"agent","output":"done"}"#, response: true)
        try handle.write(contentsOf: Data(output.utf8))
        #expect(CodexTranscript.read(url, after: first.end, queue: [])?.entries.isEmpty == true)
        try handle.write(contentsOf: Data("\n".utf8))
        let second = try #require(CodexTranscript.read(url, after: first.end, queue: []))
        #expect(second.entries == [RemoteEntry(id: "agent", kind: .toolResult, text: "done", toolID: "agent", date: date)])
        let calls = Turn.turns(from: first.entries + second.entries).flatMap(\.parts).flatMap { part -> [ToolCall] in
            switch part {
            case let .work(calls), let .cards(calls): calls
            case .reply: []
            }
        }
        #expect(calls.last?.result?.text == "done")
    }

    @Test func tailWindowExpandsAndContinuationKeepsTheFileEra() throws {
        let prompt = line(#"{"type":"item_completed","item":{"type":"UserMessage","id":"u","content":[{"type":"text","text":"Start"}]}}"#)
        let filler = line(#"{"type":"unused","message":"\#(String(repeating: "x", count: TranscriptTail.tailBytes))"}"#)
        let url = try write([prompt, filler])
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try #require(CodexTranscript.read(url, after: nil, queue: []))
        #expect(first.entries == [RemoteEntry(id: "u", kind: .prompt, text: "Start", date: date)])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let lines = [
            line(#"{"type":"function_call","name":"exec_command","call_id":"old","arguments":"{\"cmd\":\"ignored\"}"}"#, response: true),
            line(#"{"type":"function_call_output","call_id":"old","output":"ignored"}"#, response: true),
            line(#"{"type":"item_completed","item":{"type":"CommandExecution","id":"new","command":["zsh","-c","echo continued"],"aggregated_output":"continued","exit_code":0,"status":"completed"}}"#),
        ]
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        #expect(CodexTranscript.read(url, after: first.end, queue: [])?.entries == [
            RemoteEntry(id: "new", kind: .toolUse, text: #"{"command":"echo continued"}"#, toolID: "new", name: "Bash", command: "echo continued", date: date),
            RemoteEntry(id: "new-result", kind: .toolResult, text: "continued", toolID: "new", date: date),
        ])
    }
}
