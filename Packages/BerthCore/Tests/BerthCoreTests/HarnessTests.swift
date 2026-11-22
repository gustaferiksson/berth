@testable import BerthCore
import Foundation
import Testing

struct HarnessTests {
    @Test func capabilitiesMatchTheAdapters() {
        #expect(Capability.allCases.allSatisfy { Harness.claude.supports($0) })
        #expect(Harness.codex.capabilities == [.conversation, .contextSize, .pullRequestLinks, .needsYou, .idleUnload])
    }

    @Test func everyAgentHasItsHarness() {
        #expect(Harness.all.map(\.agent) == [.claude, .codex])
        #expect(Harness.all.allSatisfy { $0.agent.harness.agent == $0.agent })
        #expect(Agent.codex.name == "Codex" && Agent.claude.name == "Claude")
        #expect(Harness.all.map(\.isOptIn) == [false, true])
        #expect(Harness.all.map(\.liveSource) == [.sessionFiles, .tabSignals])
    }

    @Test func launchCommandsComeFromTheDescriptor() {
        #expect(Harness.claude.command(.resume) == ClaudeLaunch.command(.resume))
        #expect(Harness.claude.command(.newInWorktree).contains(" -w "))
        #expect(Harness.codex.command(.resume) == #"/bin/zsh -ilc 'codex -c "tui.terminal_title=[\"run-state\"]" resume "$BERTH_SESSION_ID" || exec /bin/zsh -il'"#)
        #expect(Harness.codex.command(.new) == #"/bin/zsh -ilc 'codex -c "tui.terminal_title=[\"run-state\"]" || exec /bin/zsh -il'"#)
        #expect(Harness.codex.command(.new) == Harness.codex.command(.newInWorktree))
        #expect(Harness.codex.command(.resume) == Harness.codex.command(.attach))
    }

    @Test func onlyCodexClaimsItsSessionAfterOpening() {
        let opened = Date(timeIntervalSince1970: 100)
        let session = SessionSummary(id: "rollout", cwd: "/a", title: "t", lastActivity: opened, agent: .codex, startedAt: opened.addingTimeInterval(1))
        #expect(Harness.claude.claimsNewSession == false)
        #expect(Harness.codex.claim?(opened, "/a", [session], []).map(\.id) == "rollout")
        #expect(Harness.codex.claim?(opened, "/a", [session], ["rollout"]) == nil)
    }

    @Test func adaptersReadTheirTranscriptEntries() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "harness-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello there"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"hi"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let chunk = try #require(Harness.claude.readTranscript?(url, nil, []))
        #expect(chunk.entries.map(\.kind) == [.prompt, .reply])
        let codex = #"{"timestamp":"2026-01-02T10:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}"#
        try (codex + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(Harness.codex.readTranscript?(url, nil, [])?.entries.map(\.text) == ["hello"])
    }
}
