@testable import BerthCore
import Foundation
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

@Test func pairsOverlappingShellOutputsWithTheirOwnCommandNotTheLastOne() {
    func record(_ uuid: String, parent: String, _ seconds: Int, _ content: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","parentUuid":"\#(parent)","timestamp":"1970-01-01T00:16:\#(40 + seconds).000Z","message":{"role":"user","content":"\#(content)"}}"#
    }
    let records = [
        record("slow", parent: "root", 1, "<bash-input>brew uninstall docker</bash-input>"),
        record("fast", parent: "slow", 2, "<bash-input>ls</bash-input>"),
        record("fast-out", parent: "fast", 3, "<bash-stdout>files</bash-stdout><bash-stderr></bash-stderr>"),
        record("slow-out", parent: "slow", 9, "<bash-stdout>removed</bash-stdout><bash-stderr></bash-stderr>"),
    ]
    let entries = TranscriptTail.entries(in: Data((records.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
    let prompts = Turn.turns(from: entries).compactMap(\.prompt)

    #expect(prompts.map(\.text) == ["brew uninstall docker", "ls"])
    #expect(prompts.map(\.shellOutput) == ["removed", "files"])
}
