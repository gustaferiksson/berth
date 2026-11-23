@testable import BerthCore
import Foundation
import Testing

struct CodexRolloutTests {
    private static let id = "01900000-0000-7000-8000-000000000001"

    private func meta(id: String = id, cwd: String = "/work/app", originator: String = "codex-tui", threadSource: String = "user", source: String = #""cli""#, branch: String? = "feature") -> String {
        let git = branch.map { #","git":{"commit_hash":"abc","branch":"\#($0)"}"# } ?? ""
        return #"{"timestamp":"2026-01-02T10:00:00.100Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-01-02T10:00:00.000Z","cwd":"\#(cwd)","originator":"\#(originator)","thread_source":"\#(threadSource)","source":\#(source),"base_instructions":"\#(String(repeating: "x", count: 40_000))"\#(git)}}"#
    }

    private func prompt(_ text: String, at time: String) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"user_message","message":"\#(text)","images":[]}}"#
    }

    private func reply(at time: String) -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"agent_message","message":"done","phase":"final_answer"}}"#
    }

    private func turn(cwd: String, model: String = "gpt-test") -> String {
        #"{"timestamp":"2026-01-02T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t","cwd":"\#(cwd)","model":"\#(model)"}}"#
    }

    private func tokens(input: Int, window: Int = 200_000) -> String {
        #"{"timestamp":"2026-01-02T10:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"output_tokens":5},"model_context_window":\#(window)}}}"#
    }

    private func write(_ lines: [String], in directory: URL, name: String = "rollout-2026-01-02T10-00-00-\(id).jsonl") throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "codex-rollout-\(UUID().uuidString)")
    }

    @Test func readsAnInteractiveSessionPastALargeFirstLine() throws {
        let url = try write([meta(), turn(cwd: "/work/app"), prompt("Fix the login bug", at: "2026-01-02T10:00:02.000Z"), reply(at: "2026-01-02T10:04:00.000Z"), tokens(input: 50_000)], in: scratch())
        let summary = try #require(CodexRollout.summary(of: url))
        #expect(summary.id == Self.id)
        #expect(summary.agent == .codex)
        #expect(summary.cwd == "/work/app")
        #expect(summary.title == "Fix the login bug")
        #expect(summary.branch == "feature")
        #expect(summary.lastTypedPrompt == CodexRollout.date("2026-01-02T10:00:02.000Z"))
        #expect(summary.lastActivity == CodexRollout.date("2026-01-02T10:04:00.000Z"))
        #expect(summary.startedAt == CodexRollout.date("2026-01-02T10:00:00.000Z"))
        #expect(summary.context == SessionContext(model: "gpt-test", tokens: 50_000, window: 200_000, modelName: "gpt-test"))
    }

    @Test func aRenamedSessionTakesItsName() throws {
        let url = try write([meta(), prompt("first prompt", at: "2026-01-02T10:00:02.000Z")], in: scratch())
        #expect(CodexRollout.summary(of: url, name: "Release   notes")?.title == "Release notes")
    }

    @Test func followsTheLatestTurnFolder() throws {
        let url = try write([meta(), turn(cwd: "/work/app"), prompt("hi", at: "2026-01-02T10:00:02.000Z"), turn(cwd: "/work/other")], in: scratch())
        #expect(CodexRollout.summary(of: url)?.cwd == "/work/other")
    }

    @Test func contextIsUnknownAfterACompaction() throws {
        let compacted = #"{"timestamp":"2026-01-02T10:06:00.000Z","type":"compacted","payload":{"message":""}}"#
        let url = try write([meta(), turn(cwd: "/work/app"), prompt("hi", at: "2026-01-02T10:00:02.000Z"), tokens(input: 90_000), compacted], in: scratch())
        #expect(CodexRollout.summary(of: url)?.context == nil)
    }

    @Test func contextUsesEffortFromTheLatestTurn() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = #"{"type":"turn_context","payload":{"cwd":"/work/app","model":"fixture-early","effort":"low"}}"#
        let latest = #"{"type":"turn_context","payload":{"cwd":"/work/app","model":"fixture-late","effort":"high"}}"#
        let url = try write([meta(), first, latest, prompt("Sort the colors", at: "2026-01-02T10:04:00.000Z"), tokens(input: 900)], in: directory)
        let summary = try #require(CodexRollout.summary(of: url))
        #expect(summary.context?.model == "fixture-late")
        #expect(summary.context?.effort == "high")
    }

    @Test func latestSettingsWinInRolloutOrder() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = #"{"type":"turn_context","payload":{"model":"fixture-first","effort":"low"}}"#
        let changed = #"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"fixture-changed","reasoning_effort":"high","collaboration_mode":{"mode":"plan"}}}}"#
        let nextTurn = #"{"type":"turn_context","payload":{"model":"fixture-changed","collaboration_mode":{"mode":"default","settings":{"reasoning_effort":"medium"}}}}"#
        let base = [meta(), first, prompt("Sort the colors", at: "2026-01-02T10:04:00.000Z"), tokens(input: 900)]
        let url = try write(base + [changed], in: directory)
        var summary = try #require(CodexRollout.summary(of: url))
        #expect(summary.context?.model == "fixture-changed")
        #expect(summary.context?.effort == "high")

        let continued = try write(base + [changed, nextTurn], in: directory)
        summary = try #require(CodexRollout.summary(of: continued))
        #expect(summary.context?.effort == "medium")

        let withoutTokens = try write(Array(base.dropLast()) + [changed], in: directory)
        summary = try #require(CodexRollout.summary(of: withoutTokens))
        #expect(summary.context == nil)
        #expect(Harness.codex.summaryContext?(summary)?.effort == "high")
    }

    @Test func skipsNonInteractiveSessions() throws {
        let directory = scratch()
        let lines = [prompt("hi", at: "2026-01-02T10:00:02.000Z")]
        let exec = try write([meta(originator: "codex_exec", source: #""exec""#)] + lines, in: directory, name: "rollout-a-\(Self.id).jsonl")
        let plugin = try write([meta(originator: "Claude Code")] + lines, in: directory, name: "rollout-b-\(Self.id).jsonl")
        let subagent = try write([meta(threadSource: "subagent", source: #"{"subagent":{"thread_spawn":{}}}"#)] + lines, in: directory, name: "rollout-c-\(Self.id).jsonl")
        #expect([exec, plugin, subagent].allSatisfy { CodexRollout.summary(of: $0) == nil })
    }

    @Test func hidesASessionWithNoPromptAndNoName() throws {
        let url = try write([meta(), turn(cwd: "/work/app")], in: scratch())
        #expect(CodexRollout.summary(of: url) == nil)
    }

    @Test func indexListsRolloutsAndAppliesTheNewestIndexName() throws {
        let home = scratch()
        let day = home.appending(path: "sessions/2026/01/02")
        _ = try write([meta(), prompt("hi", at: "2026-01-02T10:00:02.000Z")], in: day)
        _ = try write([meta(id: "01900000-0000-7000-8000-000000000002", originator: "codex_exec"), prompt("hi", at: "2026-01-02T10:00:02.000Z")], in: day, name: "rollout-2026-01-02T11-00-00-01900000-0000-7000-8000-000000000002.jsonl")
        let index = #"{"id":"\#(Self.id)","thread_name":"Old","updated_at":"x"}"# + "\n" + #"{"id":"\#(Self.id)","thread_name":"Newer","updated_at":"y"}"#
        try Data(index.utf8).write(to: home.appending(path: "session_index.jsonl"))
        var codex = CodexIndex(root: home)
        let sessions = codex.refresh()
        #expect(sessions.map(\.title) == ["Newer"])
    }

    @Test func readsItemMessagesAsConversation() throws {
        let first = #"{"timestamp":"2026-01-02T10:00:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":[{"type":"text","text":"Fix"},{"type":"text","text":"the fixture"}]}}}"#
        let last = #"{"timestamp":"2026-01-02T10:02:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u2","content":[{"type":"text","text":"Continue"}]}}}"#
        let agent = #"{"timestamp":"2026-01-02T10:03:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"a","content":[{"type":"text","text":"Done"}]}}}"#
        let url = try write([meta(), first, last, agent], in: scratch())
        let summary = try #require(CodexRollout.summary(of: url))
        #expect(summary.title == "Fix the fixture")
        #expect(summary.lastTypedPrompt == CodexRollout.date("2026-01-02T10:02:00.000Z"))
        #expect(summary.lastActivity == CodexRollout.date("2026-01-02T10:03:00.000Z"))
    }

    @Test func discoversPullRequestsIncrementallyAndCarriesThemInTheIndex() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let created = #"{"timestamp":"2026-01-02T10:01:00.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"pr","output":"https://github.com/example/fixture/pull/12\nSee https://github.com/example/fixture/pull/99 for context"}}"#
        let ignored = #"{"timestamp":"2026-01-02T10:01:00.000Z","type":"event_msg","payload":{"type":"agent_message","message":"https://github.com/example/fixture/pull/98"}}"#
        let url = try write([meta(), prompt("Open a fixture PR", at: "2026-01-02T10:00:02.000Z"), created, ignored], in: home.appending(path: "sessions"))
        let first = CodexRollout.pullRequests(in: url, from: 0)
        let link = PullRequestLink(repository: "example/fixture", number: 12)
        #expect(first.links == [link])
        #expect(try first.end == Data(contentsOf: url).count)
        #expect(CodexRollout.summary(of: url)?.pullRequests == [link])
        var index = CodexIndex(root: home)
        #expect(index.refresh().first?.pullRequests == [link])
        #expect(index.url(ofSession: Self.id)?.lastPathComponent == url.lastPathComponent)
        let item = #"{"timestamp":"2026-01-02T10:02:00.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"pr2","aggregated_output":"  https://github.com/example/fixture/pull/13  \nhttps://github.com/example/fixture/pull/12","status":"completed"}}}"#
        let custom = #"{"timestamp":"2026-01-02T10:02:00.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"pr3","output":[{"type":"input_text","text":"https://github.com/example/fixture/pull/14"}]}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((item + "\n" + custom + "\n").utf8))
        try handle.close()
        let second = CodexRollout.pullRequests(in: url, from: first.end)
        let next = PullRequestLink(repository: "example/fixture", number: 13)
        let third = PullRequestLink(repository: "example/fixture", number: 14)
        #expect(second.links == [next, link, third])
        #expect(index.refresh().first?.pullRequests == [link, next, third])
        #expect(CodexRollout.pullRequests(in: url, from: second.end).links.isEmpty)
        try (meta() + "\n" + prompt("Reset", at: "2026-01-02T10:04:00.000Z") + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(index.refresh().first?.pullRequests.isEmpty == true)
    }

    @Test func homeFollowsCodexHome() {
        let user = URL(filePath: "/Users/x")
        #expect(CodexIndex.home(environment: [:], user: user).path == "/Users/x/.codex")
        #expect(CodexIndex.home(environment: ["CODEX_HOME": "/tmp/h"], user: user).path == "/tmp/h")
    }
}
