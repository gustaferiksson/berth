@testable import BerthCore
import Foundation
import Testing

struct SubagentTests {
    @Test func mapsAsyncResultText() {
        let use = RemoteEntry(id: "use", kind: .toolUse, text: "{}", toolID: "launch", name: "Agent")
        let result = RemoteEntry(id: "result", kind: .toolResult, text: "Async agent launched successfully.\nagentId: docs-42 (internal ID)", toolID: "launch")
        #expect(ToolCall(use: use, result: result).agentID == "docs-42")
        #expect(ToolCall(use: use, result: nil).agentID == nil)
    }

    @Test func mapsVirtualAsyncResultText() {
        let line = #"{"type":"user","uuid":"virtual","toolUseResult":{"isAsync":true,"agentId":"docs-42"},"message":{"content":[{"type":"tool_result","tool_use_id":"repl_launch","content":""}]}}"#
        let result = TranscriptTail.entries(in: Data((line + "\n").utf8), dropFirst: false, queue: []).entries.first
        let use = RemoteEntry(id: "use", kind: .toolUse, text: "{}", toolID: "repl_launch", name: "Agent")
        #expect(ToolCall(use: use, result: result).agentID == "docs-42")
    }

    @Test func locatesAgentConversations() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "subagent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = directory.appending(path: "session.jsonl")
        let subagents = directory.appending(path: "session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let transcript = subagents.appending(path: "agent-docs-42.jsonl")
        try Data().write(to: transcript)
        try Data(#"{"description":"Review the export docs","agentType":"Explore","toolUseId":"tool-42","finished":true}"#.utf8).write(to: subagents.appending(path: "agent-docs-42.meta.json"))

        let foreground = try #require(Subagent.locate(session: session, agentID: nil, toolUseID: "tool-42"))
        #expect(foreground.id == "docs-42")
        #expect(foreground.description == "Review the export docs")
        #expect(foreground.agentType == "Explore")
        #expect(foreground.isFinished)
        #expect(foreground.url == transcript)

        let asyncPopover = Subagent.locate(session: session, agentID: "docs-42", toolUseID: "docs-42")
        #expect(asyncPopover?.id == "docs-42")
        let foregroundPopover = Subagent.locate(session: session, agentID: "tool-42", toolUseID: "tool-42")
        #expect(foregroundPopover?.id == "docs-42")
        #expect(Subagent.locate(session: session, agentID: "missing", toolUseID: "missing") == nil)
        try FileManager.default.removeItem(at: transcript)
        #expect(Subagent.locate(session: session, agentID: "docs-42", toolUseID: "tool-42") == nil)
    }

    @Test func includesSidechainOnlyWhenRequested() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sidechain-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","uuid":"prompt","isSidechain":true,"message":{"role":"user","content":"Review the export docs"}}"#,
            #"{"type":"assistant","uuid":"reply","isSidechain":true,"message":{"content":[{"type":"text","text":"The column list needs updating."}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        #expect(TranscriptTail.read(url, after: nil)?.entries.isEmpty == true)
        let chunk = try #require(TranscriptTail.read(url, after: nil, includeSidechain: true))
        #expect(chunk.entries.map(\.kind) == [.prompt, .reply])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","uuid":"next","isSidechain":true,"message":{"content":[{"type":"text","text":"Also update the CSV header."}]}}"# + "\n").utf8))
        try handle.close()
        let next = try #require(TranscriptTail.read(url, after: chunk.end, includeSidechain: true))
        #expect(next.isContinuation)
        #expect(next.entries.map(\.text) == ["Also update the CSV header."])
    }
}
