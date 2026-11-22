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

    @Test func homeFollowsCodexHome() {
        let user = URL(filePath: "/Users/x")
        #expect(CodexIndex.home(environment: [:], user: user).path == "/Users/x/.codex")
        #expect(CodexIndex.home(environment: ["CODEX_HOME": "/tmp/h"], user: user).path == "/tmp/h")
    }

    @Test func launchCommandsPassTheIDThroughTheEnvironment() {
        #expect(CodexLaunch.command(.resume) == #"/bin/zsh -ilc 'codex resume "$BERTH_SESSION_ID" || exec /bin/zsh -il'"#)
        #expect(CodexLaunch.command(.new) == "/bin/zsh -ilc 'codex || exec /bin/zsh -il'")
    }

    @Test func aNewTabClaimsTheOldestUnclaimedSessionStartedAfterItOpened() {
        let opened = Date(timeIntervalSince1970: 1000)
        func session(_ id: String, cwd: String = "/a", started: TimeInterval, agent: Agent = .codex) -> SessionSummary {
            SessionSummary(id: id, cwd: cwd, title: id, lastActivity: opened, agent: agent, startedAt: Date(timeIntervalSince1970: started))
        }
        let sessions = [session("before", started: 900), session("other", cwd: "/b", started: 1010), session("claude", started: 1010, agent: .claude), session("late", started: 1030), session("first", started: 1020)]
        #expect(CodexLaunch.claim(for: opened, cwd: "/a", in: sessions, excluding: [])?.id == "first")
        #expect(CodexLaunch.claim(for: opened, cwd: "/a", in: sessions, excluding: ["first"])?.id == "late")
    }
}
