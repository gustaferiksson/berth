@testable import BerthCore
import Foundation
import Testing

struct TranscriptTailTests {
    private let lines = [
        #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Rename the widget"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"On it."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w.swift","old_string":"old","new_string":"new"}}]}}"#,
        #"{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"\#(String(repeating: "x", count: 5000))"}]}]}}"#,
        #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"swift test"}}]}}"#,
        #"{"type":"api-request-blob","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{"command":"rm"}}]}}"#,
        #"{"type":"assistant","uuid":"s1","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}"#,
        #"{"type":"user","uuid":"m1","isMeta":true,"message":{"content":"meta"}}"#,
    ]

    @Test func readsConversationAndToolCalls() {
        let parsed = TranscriptTail.entries(in: Data((lines.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: [])
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
        let entries = TranscriptTail.entries(in: Data((capped.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
        let fields = entries.flatMap { [$0.text, $0.toolID, $0.name, $0.filePath].compactMap(\.self) }
        #expect(entries.count == 3 && fields.count == 6 && fields.allSatisfy { $0.count == TranscriptTail.maxText })
    }

    @Test func keepsOlderTurnsBehindHugeImageLines() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let small = (0..<30).flatMap { turn in
            [
                #"{"type":"user","uuid":"p\#(turn)","message":{"role":"user","content":"turn \#(turn)"}}"#,
                #"{"type":"assistant","uuid":"r\#(turn)","message":{"content":[{"type":"text","text":"reply \#(turn)"}]}}"#,
            ]
        }
        let base64 = String(repeating: "QUJD", count: 1_300_000)
        let huge = (0..<3).map { shot in
            #"{"type":"user","uuid":"i\#(shot)","message":{"content":[{"type":"tool_result","tool_use_id":"t\#(shot)","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(base64)"}}]}]}}"#
        }
        try Data(((small + huge).joined(separator: "\n") + "\n").utf8).write(to: url)

        let chunk = try #require(TranscriptTail.read(url, after: nil))
        #expect(chunk.entries.count >= TranscriptTail.minEntries)
        #expect(chunk.entries.contains { $0.text == "turn 20" })
        #expect(chunk.entries.suffix(3).allSatisfy { $0.imageRefs?.first?.bytes == base64.utf8.count * 3 / 4 })
        #expect(chunk.imageLines["i2-0-0"] != nil)
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

    @Test func followsClaudesPromptQueue() {
        let operations = [
            #"{"type":"queue-operation","operation":"dequeue"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"first"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>done</task-notification>"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"second"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"third"}"#,
            #"{"type":"queue-operation","operation":"dequeue"}"#,
            #"{"type":"queue-operation","operation":"remove","content":"third","reason":"absorbed_mid_turn"}"#,
        ]
        let parsed = TranscriptTail.entries(in: Data((operations.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: [])
        #expect(parsed.entries.isEmpty && parsed.queue == ["<task-notification>done</task-notification>", "second"])
        #expect(TranscriptTail.Chunk(entries: [], end: 0, isContinuation: true, queue: parsed.queue, imageLines: [:]).queuedPrompts == ["second"])

        let popped = TranscriptTail.entries(in: Data((#"{"type":"queue-operation","operation":"popAll","content":"second"}"# + "\n").utf8), dropFirst: false, queue: parsed.queue)
        #expect(popped.queue.isEmpty)
    }
}

struct RemoteProtocolTests {
    @Test func decodesMessagesFromTheReleasedApps() throws {
        guard case let .prompt(sessionID, text, attachments) = try JSONDecoder().decode(RemoteClientMessage.self, from: Data(#"{"prompt":{"sessionID":"s","text":"hi"}}"#.utf8)) else { throw CancellationError() }

        #expect(sessionID == "s" && text == "hi" && attachments == nil)

        guard case let .sessions(groups, folders, features) = try JSONDecoder().decode(RemoteServerMessage.self, from: Data(#"{"sessions":{"groups":[],"folders":["/f"]}}"#.utf8)) else { throw CancellationError() }

        #expect(groups.isEmpty && folders == ["/f"] && features == nil)

        guard case let .transcript(_, entries, _, queued, _) = try JSONDecoder().decode(RemoteServerMessage.self, from: Data(#"{"transcript":{"sessionID":"s","entries":[],"isContinuation":true}}"#.utf8)) else { throw CancellationError() }

        #expect(entries.isEmpty && queued == nil)

        let session = try JSONDecoder().decode(RemoteSession.self, from: Data(#"{"id":"s","title":"t","folder":"/f","lastActivity":0,"isOpen":true,"isLocked":false,"pullRequest":{"number":7,"state":"Open","url":"https://github.com/a/b/pull/7"}}"#.utf8))

        #expect(session.pullRequest?.checks == nil)
    }

    @Test func pullRequestMessagesRoundTrip() throws {
        let request = RemoteClientMessage.pullRequest(sessionID: "s")
        guard case let .pullRequest(sessionID) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(request)) else { throw CancellationError() }

        #expect(sessionID == "s")

        let reply = RemoteServerMessage.pullRequest(sessionID: "s", detail: nil)
        guard case let .pullRequest(_, detail) = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(reply)) else { throw CancellationError() }

        #expect(detail == nil)
    }

    @Test func searchMessagesRoundTrip() throws {
        let request = RemoteClientMessage.search(query: "walrus")
        guard case let .search(query) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(request)) else { throw CancellationError() }

        #expect(query == "walrus")

        let hit = RemoteSearchHit(id: "s", title: "t", folder: "/f", lastActivity: Date(timeIntervalSince1970: 0), snippets: [RemoteSnippet(text: "a walrus", highlights: [2..<8])])
        let reply = RemoteServerMessage.searchResults(query: "walrus", hits: [hit], isIndexing: true)
        guard case let .searchResults(replyQuery, hits, isIndexing) = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(reply)) else { throw CancellationError() }

        #expect(replyQuery == "walrus" && hits == [hit] && isIndexing)
    }
}
