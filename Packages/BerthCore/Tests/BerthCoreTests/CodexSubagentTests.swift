import BerthCore
import Foundation
import Testing

struct CodexSubagentTests {
    @Test func readsOpenChildrenAndLocatesTheirRollouts() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-children-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appending(path: "sessions/2026/01/02")
        let nextDay = root.appending(path: "sessions/2026/01/03")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nextDay, withIntermediateDirectories: true)

        let parent = "419fdb4f-74c6-4334-a7fe-5f9aaaec4a31"
        let child = "fd013fe6-dd14-4570-bcbf-dbbb8637ab09"
        let parentMeta = #"{"id":"\#(parent)","source":"cli"}"#
        let childMeta = #"{"id":"\#(child)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","agent_path":"/root/docs","agent_nickname":"Iris","agent_role":"Reviewer"}}}}"#
        let otherMeta = childMeta.replacing(parent, with: "a7920f98-9853-4c36-a5e9-310ade06ac35")
        let parentURL = day.appending(path: "rollout-2026-01-02T22-00-00-\(parent).jsonl")
        let wrongURL = day.appending(path: "rollout-2026-01-02T23-00-00-\(child).jsonl")
        let childURL = nextDay.appending(path: "rollout-2026-01-03T01-00-00-\(child).jsonl")
        try write([
            ("session_meta", parentMeta),
            ("event_msg", #"{"type":"user_message","message":"Check the docs"}"#),
            ("response_item", #"{"type":"function_call","name":"spawn_agent","call_id":"spawn","arguments":"{\"message\":\"Review the export docs\",\"task_name\":\"docs\"}"}"#),
            ("event_msg", #"{"type":"item_completed","item":{"type":"SubAgentActivity","kind":"started","id":"spawn","agent_thread_id":"\#(child)","agent_path":"/root/docs"}}"#),
            ("response_item", #"{"type":"function_call_output","call_id":"spawn","output":"Agent started"}"#),
        ], to: parentURL)
        let open = ("event_msg", #"{"type":"task_started"}"#)
        try write([("session_meta", otherMeta), ("session_meta", childMeta), open], to: wrongURL)
        let harness = Harness.codex
        #expect(harness.locateSubagent(root, parentURL, child, nil) == nil)

        try write([("session_meta", childMeta), ("session_meta", parentMeta), open], to: childURL)
        let task = try #require(harness.readTasks?(root, parentURL).first)
        #expect(task.id == child)
        #expect(task.kind == RemoteTask.agent)
        #expect(task.title == "Review the export docs")
        #expect(task.agentType == "Reviewer")
        #expect(task.started == Date(timeIntervalSince1970: 1_767_362_400))
        #expect(task.toolUseID == "spawn")
        let found = try #require(harness.locateSubagent(root, parentURL, nil, "spawn"))
        #expect(found.url.resolvingSymlinksInPath().path == childURL.resolvingSymlinksInPath().path)
        #expect(harness.locateSubagent(root, parentURL, child, nil)?.id == child)

        let entries = try #require(harness.readTranscript?(parentURL, nil, [])).entries
        let turn = try #require(Turn.turns(from: entries).first)
        #expect(turn.parts.contains { part in
            if case let .cards(calls) = part { return calls.first?.cardTitle == "Review the export docs" }

            return false
        })

        let complete = ("event_msg", #"{"type":"task_complete"}"#)
        try write([("session_meta", childMeta), ("session_meta", parentMeta), open, complete], to: childURL)
        #expect(harness.readTasks?(root, parentURL).isEmpty == true)
        #expect(harness.locateSubagent(root, parentURL, nil, "spawn")?.isFinished == true)
    }

    private func write(_ items: [(String, String)], to url: URL) throws {
        let lines = items.map { #"{"timestamp":"2026-01-02T14:00:00.000Z","type":"\#($0.0)","payload":\#($0.1)}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
