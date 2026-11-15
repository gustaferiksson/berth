import Foundation
import Testing
@testable import BerthCore

struct TranscriptTailTests {
    let lines = [
        #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Rename the widget"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"On it."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w.swift","old_string":"old","new_string":"new"}}]}}"#,
        #"{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"\#(String(repeating: "x", count: 5000))"}]}]}}"#,
        #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test"}}]}}"#,
        #"{"type":"api-request-blob","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"rm"}}]}}"#,
        #"{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#,
        #"{"type":"user","uuid":"m1","isMeta":true,"message":{"content":"meta"}}"#,
    ]

    @Test func readsConversationAndToolCalls() {
        let parsed = TranscriptTail.entries(in: Data((lines.joined(separator: "\n") + "\n").utf8), dropFirst: false)
        #expect(parsed.entries.map(\.kind) == [.prompt, .reply, .toolUse, .toolResult, .toolUse])
        #expect(parsed.entries[0].text == "Rename the widget")
        #expect(parsed.entries[2].filePath == "/w.swift" && parsed.entries[2].oldText == "old" && parsed.entries[2].newText == "new")
        #expect(parsed.entries[3].toolID == "t1" && parsed.entries[3].text.count == TranscriptTail.maxText)
        #expect(parsed.entries[4].command == "swift test" && parsed.entries[4].toolID == "t2")
    }

    @Test func capsEveryField() {
        let long = String(repeating: "y", count: 5000)
        let capped = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"\#(long)"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"\#(long)"},{"type":"tool_use","id":"\#(long)","name":"\#(long)","input":{"file_path":"\#(long)"}}]}}"#,
        ]
        let entries = TranscriptTail.entries(in: Data((capped.joined(separator: "\n") + "\n").utf8), dropFirst: false).entries
        let fields = entries.flatMap { [$0.text, $0.toolID, $0.name, $0.filePath].compactMap(\.self) }
        #expect(entries.count == 3 && fields.count == 6 && fields.allSatisfy { $0.count == TranscriptTail.maxText })
    }

    @Test func continuesFromTheLastCompleteLine() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((lines[0] + "\n" + lines[3].prefix(20)).utf8).write(to: url)

        let first = try #require(TranscriptTail.read(url, after: nil))
        #expect(first.entries.map(\.id) == ["u1"] && !first.isContinuation)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines[3].dropFirst(20) + "\n").utf8))
        try handle.close()

        let next = try #require(TranscriptTail.read(url, after: first.end))
        #expect(next.isContinuation && next.entries.map(\.id) == ["a2-0"])
        #expect(TranscriptTail.read(url, after: next.end)?.entries.isEmpty == true)
    }
}
