import BerthCore
import Foundation
import Testing

struct CodexLaunchTests {
    @Test func launchesWithCodexDefaults() {
        #expect(CodexLaunch.command(.new, LaunchOptions()) == #"/bin/zsh -ilc 'codex -c "tui.terminal_title=[\"run-state\"]" || exec /bin/zsh -il'"#)
    }

    @Test func addsOptionsBeforeTheResumeSubcommand() {
        let options = LaunchOptions(model: "fixture_v1.2", effort: "high")
        #expect(CodexLaunch.command(.new, options) == #"/bin/zsh -ilc 'codex -c "tui.terminal_title=[\"run-state\"]" -m fixture_v1.2 -c model_reasoning_effort=high || exec /bin/zsh -il'"#)
        #expect(CodexLaunch.command(.resume, options) == #"/bin/zsh -ilc 'codex -c "tui.terminal_title=[\"run-state\"]" -m fixture_v1.2 -c model_reasoning_effort=high resume "$BERTH_SESSION_ID" || exec /bin/zsh -il'"#)
    }

    @Test func dropsInvalidOptionValuesIndependently() {
        let plain = CodexLaunch.command(.new, LaunchOptions())
        #expect(CodexLaunch.command(.new, LaunchOptions(model: "two words", effort: "high; echo fixture")) == plain)
        #expect(CodexLaunch.command(.new, LaunchOptions(model: "fixture\n", effort: "high")) == CodexLaunch.command(.new, LaunchOptions(effort: "high")))
        #expect(CodexLaunch.command(.new, LaunchOptions(model: "fixture-model", effort: "")) == CodexLaunch.command(.new, LaunchOptions(model: "fixture-model")))
    }

    @Test func runsCodexWithItsOptionsInsideAWorktree() {
        let options = LaunchOptions(model: "fixture-model", effort: "low")
        #expect(CodexLaunch.command(.newInWorktree, options) == #"/bin/zsh -ilc 'wt switch --create "codex-$(date +%m%d-%H%M%S)" --no-cd -x codex -- -c "tui.terminal_title=[\"run-state\"]" -m fixture-model -c model_reasoning_effort=low || exec /bin/zsh -il'"#)
    }

    @Test func claimsTheEarliestEligibleExactMatch() {
        let opened = Date(timeIntervalSince1970: 1000)
        func session(_ id: String, cwd: String = "/a", started: TimeInterval, agent: Agent = .codex) -> SessionSummary {
            SessionSummary(id: id, cwd: cwd, title: id, lastActivity: opened, agent: agent, startedAt: Date(timeIntervalSince1970: started))
        }
        let sessions = [session("before", started: 900), session("other", cwd: "/b", started: 1010), session("claude", started: 1010, agent: .claude), session("late", started: 1030), session("first", started: 1020)]
        #expect(CodexLaunch.claim(for: opened, cwd: "/a", in: sessions, excluding: [])?.id == "first")
        #expect(CodexLaunch.claim(for: opened, cwd: "/a", in: sessions, excluding: ["first"])?.id == "late")
    }

    @Test func prefersExactThenClaimsALinkedWorktreeOfTheSameRepository() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "codex-claim-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo")
        let source = repo.appending(path: "src")
        let worktree = root.appending(path: "repo.worktrees/fixture")
        let otherRepo = root.appending(path: "other")
        let otherWorktree = root.appending(path: "other.worktrees/fixture")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (checkout, linked) in [(repo, worktree), (otherRepo, otherWorktree)] {
            let gitDirectory = checkout.appending(path: ".git/worktrees/fixture")
            try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: linked.appending(path: "src"), withIntermediateDirectories: true)
            try "gitdir: \(gitDirectory.path)\n".write(to: linked.appending(path: ".git"), atomically: true, encoding: .utf8)
            try "../..\n".write(to: gitDirectory.appending(path: "commondir"), atomically: true, encoding: .utf8)
        }

        let opened = Date(timeIntervalSince1970: 1000)
        let cwd = source.path
        let candidates = [
            (id: "exact", folder: cwd, delay: 5.0),
            (id: "later-worktree", folder: worktree.path, delay: 4.0),
            (id: "worktree", folder: worktree.appending(path: "src").path, delay: 3.0),
            (id: "main", folder: repo.path, delay: 2.0),
            (id: "other", folder: otherWorktree.path, delay: 1.0),
        ]
        let sessions = candidates.map { candidate in
            SessionSummary(id: candidate.id, cwd: candidate.folder, title: candidate.id, lastActivity: opened, agent: .codex, startedAt: opened.addingTimeInterval(candidate.delay))
        }
        #expect(CodexLaunch.claim(for: opened, cwd: cwd, in: sessions, excluding: [])?.id == "exact")
        #expect(CodexLaunch.claim(for: opened, cwd: cwd, in: sessions, excluding: ["exact"])?.id == "worktree")
        #expect(CodexLaunch.claim(for: opened, cwd: cwd, in: sessions, excluding: ["exact", "worktree"])?.id == "later-worktree")
        #expect(CodexLaunch.claim(for: opened, cwd: cwd, in: sessions, excluding: ["exact", "worktree", "later-worktree"]) == nil)
    }
}
