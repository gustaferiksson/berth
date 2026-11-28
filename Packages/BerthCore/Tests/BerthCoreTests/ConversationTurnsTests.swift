@testable import BerthCore
import Testing

@Test func textContinuationKeepsEarlierCallsAndHandlesTheNextPrompt() throws {
    let entries = [
        RemoteEntry(id: "prompt", kind: .prompt, text: "Check the docs"),
        RemoteEntry(id: "read", kind: .toolUse, text: "{}", toolID: "tool", name: "Read"),
        RemoteEntry(id: "output", kind: .toolResult, text: "docs", toolID: "tool"),
    ]
    let initial = Turn.turns(from: entries)
    let appended = [
        RemoteEntry(id: "reply", kind: .reply, text: "Checked"),
        RemoteEntry(id: "stop", kind: .prompt, text: "[Request interrupted by user]"),
        RemoteEntry(id: "next", kind: .prompt, text: "Check again"),
    ]
    let updated = try #require(Turn.continuing(initial, with: appended))

    #expect(updated.map(\.id) == ["prompt", "next"])
    #expect(updated[0].parts.map(\.id) == ["read", "reply"])
    #expect(updated[0].isInterrupted)
    #expect(initial[0].parts.map(\.id) == ["read"])
    guard case let .work(calls) = updated[0].parts.first else {
        Issue.record("Expected the earlier call")
        return
    }

    #expect(calls.first?.result?.text == "docs")
    #expect(Turn.continuing(updated, with: [RemoteEntry(id: "late", kind: .toolResult, text: "updated", toolID: "tool")]) == nil)
}

@Test func searchSnippetFindsTheNewestTurnWithThatText() {
    let turns = Turn.turns(from: [
        RemoteEntry(id: "p1", kind: .prompt, text: "Why does the feed jump?"),
        RemoteEntry(id: "r1", kind: .reply, text: "The feed rebuilds **every row** when a new entry arrives."),
        RemoteEntry(id: "p2", kind: .prompt, text: "Fix it"),
        RemoteEntry(id: "r2", kind: .reply, text: "Rows now use entry IDs.\n\nThe feed rebuilds every row only once."),
    ])
    let snippet = { RemoteSnippet(text: $0, highlights: []) }

    #expect(Turn.id(matching: snippet("…feed rebuilds every row when a new…"), in: turns) == "p1")
    #expect(Turn.id(matching: snippet("Rows now use entry IDs. The feed rebuilds every row"), in: turns) == "p2")
    #expect(Turn.id(matching: snippet("feed rebuilds every row"), in: turns) == "p2")
    #expect(Turn.id(matching: snippet("Fix it"), in: turns) == "p2")
    #expect(Turn.id(matching: snippet("not in the transcript"), in: turns) == nil)
    #expect(Turn.id(matching: snippet("…"), in: turns) == nil)
}

@Test func pollIsNotATurnPartAndReplyKeepsItsPlace() {
    let entries = [
        RemoteEntry(id: "p", kind: .prompt, text: "go"),
        RemoteEntry(id: "r1", kind: .toolUse, text: "{}", toolID: "t1", name: "REPL"),
        RemoteEntry(id: "r2", kind: .toolUse, text: "{}", toolID: "t2", name: "Poll"),
        RemoteEntry(id: "r3", kind: .reply, text: "Done so far"),
        RemoteEntry(id: "r4", kind: .toolUse, text: "{}", toolID: "t3", name: "REPL"),
    ]
    let parts = Turn.turns(from: entries)[0].parts

    #expect(parts.count == 3)
    #expect(parts[0].isWork && !parts[1].isWork && parts[2].isWork)
}

@Test func scriptWithInnerCallsShowsThemInsteadOfTheWrapper() {
    let entries = [
        RemoteEntry(id: "p", kind: .prompt, text: "go"),
        RemoteEntry(id: "a", kind: .toolUse, text: "{}", toolID: "toolu_1", name: "REPL", detail: "List docs"),
        RemoteEntry(id: "b", kind: .toolUse, text: "{}", toolID: "toolu_2", name: "Poll"),
        RemoteEntry(id: "c", kind: .toolUse, text: "{}", toolID: "repl_1", name: "Bash", command: "ls docs"),
        RemoteEntry(id: "d", kind: .toolResult, text: "a.md", toolID: "repl_1"),
        RemoteEntry(id: "e", kind: .toolUse, text: "{}", toolID: "repl_2", name: "Read", filePath: "/x/a.md"),
        RemoteEntry(id: "f", kind: .toolResult, text: "line", toolID: "repl_2"),
        RemoteEntry(id: "g", kind: .toolUse, text: "{}", toolID: "toolu_3", name: "REPL", detail: "Compute"),
    ]
    let parts = Turn.turns(from: entries)[0].parts
    guard case let .work(calls) = parts[0] else { Issue.record("expected work"); return }

    #expect(calls.map(\.use.name) == ["Bash", "Read", "REPL"])
    #expect(calls.map(\.kind) == [.command, .read, .other])
    #expect(ToolCall.summary(of: Array(calls.prefix(2))) == "Ran 1 command and read 1 file")
}

@Test func skillCallsAreCountedAsLoadedSkills() {
    let entries = [
        RemoteEntry(id: "a", kind: .toolUse, text: "{}", toolID: "toolu_1", name: "Skill", detail: "acme:review"),
        RemoteEntry(id: "b", kind: .toolUse, text: "{}", toolID: "toolu_2", name: "Skill", detail: "acme:deploy"),
        RemoteEntry(id: "c", kind: .toolUse, text: "{}", toolID: "toolu_3", name: "Bash", detail: "List"),
    ]
    guard case let .work(calls) = Turn.turns(from: entries)[0].parts[0] else { Issue.record("expected work"); return }

    #expect(calls.map(\.kind) == [.skill, .skill, .command])
    #expect(calls[0].subject == "acme:review")
    #expect(ToolCall.summary(of: calls) == "Loaded 2 skills and ran 1 command")
    #expect(ToolCall.summary(of: [calls[0]]) == "Loaded 1 skill")
}

@Test func failedScriptShowsItsErrorRowInsteadOfTheWrapper() {
    let entries = [
        RemoteEntry(id: "p", kind: .prompt, text: "go"),
        RemoteEntry(id: "a", kind: .toolUse, text: "{}", toolID: "toolu_1", name: "REPL"),
        RemoteEntry(id: "b", kind: .toolUse, text: "{}", toolID: "repl-error-1", name: "REPL"),
        RemoteEntry(id: "c", kind: .toolResult, text: "ReferenceError: x", toolID: "repl-error-1", isError: true),
    ]
    let parts = Turn.turns(from: entries)[0].parts
    guard case let .work(calls) = parts[0] else { Issue.record("expected work"); return }

    #expect(calls.map(\.id) == ["b"])
    #expect(calls[0].result?.isError == true)
}
