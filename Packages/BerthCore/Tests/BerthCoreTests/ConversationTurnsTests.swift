@testable import BerthCore
import Testing

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
