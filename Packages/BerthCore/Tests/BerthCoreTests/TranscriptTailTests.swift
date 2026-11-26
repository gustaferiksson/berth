@testable import BerthCore
import Foundation
import Testing

struct TranscriptTailTests {
    private let lines = [
        #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Rename the widget"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"","signature":"eHh4eG5hcnJhdGlvbnh4eHg="},{"type":"text","text":"On it."},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w.swift","old_string":"old","new_string":"new"}}]}}"#,
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

    @Test func skipsAStandaloneSystemReminderBeforeThePrompt() {
        let line = #"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":" <system-reminder>\nA lantern is lit.\n</system-reminder>\n"},{"type":"text","text":"Sketch the island"}]}}"#
        let entries = TranscriptTail.entries(in: Data((line + "\n").utf8), dropFirst: false, queue: []).entries

        #expect(entries.map(\.text) == ["Sketch the island"])
    }

    @Test(arguments: [#"</pasted_content id="p1">"#, "</pasted_content>"]) func unwrapsAPromptRecordedAsOnePastedBlock(closing: String) {
        let text = "\\n\\n<pasted_content id=\\\"p1\\\">\\nrename the lantern\\nand light it" + closing.replacing("\"", with: "\\\"")
        let line = #"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
        let entries = TranscriptTail.entries(in: Data((line + "\n").utf8), dropFirst: false, queue: []).entries

        #expect(entries.map(\.text) == ["rename the lantern\nand light it"])
    }

    @Test func splitsAPastedBlockInsideTypedText() {
        let parts = PromptTextPart.split("regarding this\n<pasted_content id=\"p2\">\nlamps: string[]\n</pasted_content id=\"p2\">\n\nis it fine?")

        guard parts.count == 3, case let .text(before) = parts[0], case let .pasted(block) = parts[1], case let .text(after) = parts[2] else {
            Issue.record("unexpected parts \(parts)")
            return
        }

        #expect(before == "regarding this\n" && block == "lamps: string[]" && after == "\n\nis it fine?")
        #expect(PromptTextPart.removingImageTags([228, 230], from: "[Image #228]\n\n this is a\n\n\nthis is b\n\n[Image #230]") == "this is a\n\nthis is b")
        #expect(PromptTextPart.removingImageTags([1], from: "see [Image #2] here") == "see [Image #2] here")
        #expect(PromptTextPart.plain("a <pasted_content>b</pasted_content> c") == "a b c")
    }

    @Test func joinsAllPromptTextBlocksInOrder() {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"Sketch the island"},{"type":"text","text":"<system-reminder>Omit this banner</system-reminder>"},{"type":"text","text":"Add four trees"}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"content":[{"type":"text","text":"<system-reminder>Omit this too</system-reminder>"}]}}"#,
        ]
        let entries = TranscriptTail.entries(in: Data((lines.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries

        #expect(entries.map(\.text) == ["Sketch the island\nAdd four trees"])
    }

    @Test func foldsBashOutputIntoItsPrompt() throws {
        let records = [
            #"{"type":"user","uuid":"shell","message":{"role":"user","content":"<bash-input>git status</bash-input>"}}"#,
            #"{"type":"user","uuid":"output","message":{"role":"user","content":"<bash-stdout>\nOn branch main\nWorking tree clean\n</bash-stdout><bash-stderr>\nwarning: sample warning\n</bash-stderr>"}}"#,
            lines[0],
        ]
        let entries = TranscriptTail.entries(in: Data((records.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
        #expect(entries.map(\.kind) == [.prompt, .toolResult, .prompt])
        let output = try #require(entries.dropFirst().first)
        #expect(output.id == "output" && output.name == "bash-output" && output.toolID == nil)

        let turns = Turn.turns(from: entries)
        #expect(turns.map(\.id) == ["shell", "u1"])
        let prompt = try #require(turns.first?.prompt)
        #expect(prompt.name == "bash" && prompt.text == "git status" && prompt.command == "git status")
        #expect(prompt.shellOutput == "On branch main\nWorking tree clean")
        #expect(prompt.shellError == "warning: sample warning")
        #expect(turns.first?.parts.isEmpty == true)
        #expect(turns.last?.prompt == RemoteEntry(id: "u1", kind: .prompt, text: "Rename the widget"))
        #expect(Turn.turns(from: [output]).isEmpty)
    }

    @Test func showsMidTurnUpdatesAsReplies() {
        let updates = [
            #"{"type":"assistant","uuid":"n1","message":{"content":[{"type":"thinking","thinking":"Checking the widget now.","signature":"eHh4eG5hcnJhdGlvbnh4eHg="},{"type":"thinking","thinking":"Private reasoning.","signature":"eHh4eHRoaW5raW5neHh4eA=="},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}},{"type":"thinking","thinking":"","signature":"eHh4eG5hcnJhdGlvbnh4eHg="}]}}"#,
        ]
        let entries = TranscriptTail.entries(in: Data((updates.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
        #expect(entries.map(\.kind) == [.reply, .toolUse])
        #expect(entries[0].text == "Checking the widget now.")
    }

    @Test func capsToolFieldsAndKeepsLongProse() {
        let long = String(repeating: "y", count: 5000)
        let capped = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"\#(long)"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"\#(long)"},{"type":"tool_use","id":"\#(long)","name":"\#(long)","input":{"file_path":"\#(long)"}}]}}"#,
        ]
        let entries = TranscriptTail.entries(in: Data((capped.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
        let fields = entries.filter { $0.kind == .toolUse }.flatMap { [$0.text, $0.toolID, $0.name, $0.filePath].compactMap(\.self) }
        #expect(entries.map(\.kind) == [.prompt, .reply, .toolUse])
        #expect(entries.prefix(2).map(\.text) == [long, long])
        #expect(fields.count == 4 && fields.allSatisfy { $0.count == TranscriptTail.maxText })
    }

    @Test func keepsImageTagsInlineWhenTheTranscriptSplitsTheText() {
        let line = #"{"type":"user","uuid":"u1","message":{"content":[{"type":"text","text":"get these in "},{"type":"text","text":"[Image #3]"},{"type":"text","text":" tables"},{"type":"text","text":"and last "},{"type":"text","text":"[Image #4]"}]}}"#
        let entries = TranscriptTail.entries(in: Data((line + "\n").utf8), dropFirst: false, queue: []).entries
        #expect(entries.map(\.text) == ["get these in [Image #3] tables\nand last [Image #4]"])
    }

    @Test func capsProseAndMarksTheDroppedCharacters() {
        let limit = String(repeating: "é", count: 100_000)
        let long = limit + "🧑‍💻abc"
        let records = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"\#(long)"}}"#,
            #"{"type":"attachment","uuid":"u2","attachment":{"type":"queued_command","commandMode":"prompt","humanTurn":true,"prompt":"\#(long)"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"\#(long)"}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"\#(limit)"}]}}"#,
        ]
        let entries = TranscriptTail.entries(in: Data((records.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
        let marked = limit + "\n\n[Message truncated, 4 more characters not shown]"
        #expect(entries.map(\.text) == [marked, marked, marked, limit])
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

    @Test func readsVirtualResultsFromToolUseResult() {
        let lines = [
            #"{"type":"user","uuid":"u1","isVirtual":true,"toolUseResult":{"stdout":"one\ntwo","stderr":"","interrupted":false},"message":{"content":[{"type":"tool_result","tool_use_id":"repl_1","content":""}]}}"#,
            #"{"type":"user","uuid":"u2","isVirtual":true,"toolUseResult":{"type":"text","file":{"filePath":"/x/a.md","content":"hello","numLines":1}},"message":{"content":[{"type":"tool_result","tool_use_id":"repl_2","content":""}]}}"#,
            #"{"type":"user","uuid":"u3","isVirtual":true,"toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"agent-9"},"message":{"content":[{"type":"tool_result","tool_use_id":"repl_3","content":""}]}}"#,
            #"{"type":"user","uuid":"u4","isVirtual":true,"toolUseResult":{"stdout":"started","backgroundTaskId":"bg-1"},"message":{"content":[{"type":"tool_result","tool_use_id":"repl_4","content":""}]}}"#,
            #"{"type":"user","uuid":"u5","isVirtual":true,"toolUseResult":{"error":"boom"},"message":{"content":[{"type":"tool_result","tool_use_id":"repl-error-5","content":"ReferenceError: boom","is_error":true}]}}"#,
        ]
        let entries = TranscriptTail.entries(in: Data((lines.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
        let calls = entries.map { ToolCall(use: RemoteEntry(id: "x", kind: .toolUse, text: "{}", name: "Agent"), result: $0) }

        #expect(entries.map(\.text) == ["one\ntwo", "hello", "Async agent launched successfully.\nagentId: agent-9", "Command running in background with ID: bg-1", "ReferenceError: boom"])
        #expect(calls[2].isAsyncLaunch)
    }

    @Test func keepsPromptsBehindOneLongToolTurn() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let prompts = (0..<6).map { #"{"type":"user","uuid":"p\#($0)","message":{"role":"user","content":"prompt \#($0)"}}"# }
        let output = String(repeating: "x", count: 3000)
        let calls = (0..<200).flatMap { call in
            [
                #"{"type":"assistant","uuid":"a\#(call)","isVirtual":true,"message":{"content":[{"type":"tool_use","id":"t\#(call)","name":"REPL","input":{"code":"poll"}}]}}"#,
                #"{"type":"user","uuid":"r\#(call)","turnCompanion":true,"message":{"content":[{"type":"tool_result","tool_use_id":"t\#(call)","content":"\#(output)"}]}}"#,
            ]
        }
        try Data(((prompts + calls).joined(separator: "\n") + "\n").utf8).write(to: url)

        let chunk = try #require(TranscriptTail.read(url, after: nil))
        #expect(chunk.entries.count(where: { $0.kind == .prompt }) == 6)
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

    @Test func deliveredPromptClearsItsQueueItemEvenWhenTheQueueDrifted() {
        let stale = #"{"type":"queue-operation","operation":"enqueue","content":"<event kind=\"task\">never dequeued</event>"}"#
        let sent = [
            #"{"type":"queue-operation","operation":"enqueue","content":"add a border"}"#,
            #"{"type":"queue-operation","operation":"dequeue"}"#,
        ]
        let delivered = #"{"type":"user","uuid":"u1","promptSource":"queued","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"add a border"}]}}"#
        let first = TranscriptTail.entries(in: Data(([stale] + sent).joined(separator: "\n").utf8 + Data("\n".utf8)), dropFirst: false, queue: [])
        #expect(first.queue.contains("add a border"))

        let next = TranscriptTail.entries(in: Data((delivered + "\n").utf8), dropFirst: false, queue: first.queue)
        #expect(next.entries.map(\.text) == ["add a border"])
        #expect(!next.queue.contains("add a border"))

        let together = TranscriptTail.entries(in: Data(([stale] + sent + [delivered]).joined(separator: "\n").utf8 + Data("\n".utf8)), dropFirst: false, queue: [])
        #expect(!together.queue.contains { !$0.hasPrefix("<") })
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
