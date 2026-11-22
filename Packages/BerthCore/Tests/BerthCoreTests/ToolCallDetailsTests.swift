import BerthCore
import Testing

@Test func editDetailsKeepSummaryAndDiffTogether() {
    let use = RemoteEntry(id: "edit", kind: .toolUse, text: "", name: "Edit", filePath: "/repo/file.swift", oldText: "keep\nold", newText: "keep\nnew\nextra")
    let result = RemoteEntry(id: "result", kind: .toolResult, text: "Updated")
    let details = ToolCall(use: use, result: result).details

    #expect(details.summary?.text == "Added 2 lines, removed 1 line")
    #expect(details.summary?.isError == false)
    #expect(details.arguments == "/repo/file.swift")
    #expect(details.diff.map(\.text) == ["keep", "old", "new", "extra"])
    #expect(details.diff.map(\.kind) == [.context, .removed, .added, .added])
}

@Test func pendingAndFailedWritesHaveNoDiff() {
    let use = RemoteEntry(id: "write", kind: .toolUse, text: "", name: "Write", newText: "a\nb")
    let pending = ToolCall(use: use, result: nil).details
    let failed = ToolCall(use: use, result: RemoteEntry(id: "result", kind: .toolResult, text: "Denied\nTry again", isError: true)).details

    #expect(pending.summary == nil)
    #expect(pending.diff.isEmpty)
    #expect(failed.summary?.text == "Denied")
    #expect(failed.summary?.isError == true)
    #expect(failed.summary?.moreLines == 1)
    #expect(failed.diff.isEmpty)
}
