import BerthCore
import Foundation
import Testing

struct SlashCommandsTests {
    @Test func loadsCommandsForEachHarnessFromFixtureHomeAndProject() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "slash-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let project = home.appending(path: "ledger")
        let cwd = project.appending(path: "tools")
        let plugin = home.appending(path: ".claude/plugins/cache/ledger-kit")
        let fixture = [
            ".claude/commands/shared.md": "User command",
            ".claude/commands/nested/check-ledger.md": "---\ndisable-model-invocation: true\n---\n\nCheck the ledger.\nMore detail.",
            ".claude/commands/model.md": "Cannot replace a built-in",
            ".claude/skills/private/SKILL.md": "---\nuser-invocable: false\n---\nHidden skill",
            ".claude/skills/ledger/SKILL.md": "---\nname: reconcile\ndescription: |\n  Reconcile\n  balances.\n---\nBody",
            ".claude/plugins/installed_plugins.json": #"{"version":2,"plugins":{"ledger-kit@fixture":[{"scope":"user","installPath":"\#(plugin.path)"}]}}"#,
            ".claude/plugins/cache/ledger-kit/commands/balance.md": "---\ndescription: 'Calculate the balance.'\nargument-hint: <month>\n---\nBody",
            ".claude/plugins/cache/ledger-kit/skills/export/SKILL.md": "Export the ledger.",
            ".claude/plugins/cache/ledger-kit/skills/private/SKILL.md": "---\nuser-invocable: false\n---\nHidden plugin skill",
            ".codex/prompts/balance.md": "---\ndescription: Prepare a balance report.\n---\nBody",
            ".codex/prompts/format.md": "\nFormat the report.\nMore detail.",
            "ledger/.claude/commands/shared.md": "Project command",
            "ledger/.claude/commands/check-ledger.md": "Root command",
            "ledger/tools/.claude/commands/check-ledger.md": "Working folder command",
        ]
        try FileManager.default.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        for (relativePath, contents) in fixture {
            let file = home.appending(path: relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }

        let claude = SlashCommand.load(home: home, folder: cwd, harness: .claude)
        #expect(claude.map(\.name) == [
            "/add-dir", "/advisor", "/agents", "/auto-mode-setup", "/autocompact", "/batch", "/claude-api", "/clear",
            "/code-review", "/color", "/compact", "/config", "/context", "/cost", "/debug", "/doctor", "/effort",
            "/fast", "/fewer-permission-prompts", "/focus", "/goal", "/heapdump", "/import", "/init", "/insights",
            "/list-agents", "/loop", "/mcp", "/model", "/output-style", "/recap", "/reload-plugins", "/reload-skills",
            "/rename", "/review", "/run", "/security-review", "/simplify", "/skill-doctor", "/team-onboarding",
            "/update-config", "/usage", "/verify",
            "/check-ledger", "/shared", "/reconcile", "/ledger-kit:balance", "/ledger-kit:export",
        ])
        #expect(SlashCommand.claudeBuiltIns.contains { $0.name == "/reload-skills" })
        #expect(claude.filter(\.requiresArguments).map(\.name) == ["/add-dir", "/model"])
        #expect(claude.first { $0.name == "/compact" }?.argumentHint == "[instructions]")
        #expect(claude.suffix(5).map(\.source) == ["project", "project", "user", "ledger-kit", "ledger-kit"])
        #expect(claude.suffix(5).map(\.summary) == ["Working folder command", "Project command", "Reconcile balances.", "Calculate the balance.", "Export the ledger."])
        #expect(claude.first { $0.name == "/ledger-kit:balance" }?.argumentHint == "<month>")
        #expect(SlashCommand.load(home: home, folder: nil, harness: .claude).first { $0.name == "/check-ledger" }?.summary == "Check the ledger.")

        let codex = SlashCommand.load(home: home, folder: cwd, harness: .codex)
        #expect(codex.map(\.name) == ["/compact", "/init", "/review", "/status", "/prompts:balance", "/prompts:format"])
        #expect(codex.filter(\.requiresArguments).map(\.name) == ["/review"])
        #expect(codex.suffix(2).map(\.summary) == ["Prepare a balance report.", "Format the report."])
    }

    @Test func ranksPrefixMatchesBeforeFuzzyMatches() {
        let commands = SlashCommand.builtIns(for: .claude)
        #expect(SlashCommand.matching("/", in: commands) == commands)
        #expect(SlashCommand.matching("/co", in: commands).map(\.name) == [
            "/code-review", "/color", "/compact", "/config", "/context", "/cost",
            "/autocompact", "/update-config", "/doctor", "/skill-doctor",
        ])
        #expect(SlashCommand.matching("/re", in: commands).prefix(6).map(\.name) == [
            "/recap", "/reload-plugins", "/reload-skills", "/rename", "/review", "/code-review",
        ])
        #expect(SlashCommand.matching("/mdl", in: commands).map(\.name) == ["/model"])
        #expect(SlashCommand.matching("/zz", in: commands).isEmpty)
    }
}
