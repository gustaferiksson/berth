import Foundation
import Testing
@testable import BerthCore

struct TranscriptSearchTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "berth-search-\(UUID().uuidString)")

    func source(_ id: String, _ lines: [String]) throws -> TranscriptSearchIndex.Source {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(id).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return TranscriptSearchIndex.Source(sessionID: id, url: url, modified: values.contentModificationDate ?? .now, size: values.fileSize ?? 0)
    }

    func session(_ id: String, minutesAgo: Double) -> SessionSummary {
        SessionSummary(id: id, cwd: "/Users/example/Repos/\(id)", title: id, lastActivity: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    func prompt(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"},"cwd":"/x"}"#
    }

    func reply(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
    }

    @Test func indexesTypedPromptsAndRepliesOnly() throws {
        var index = TranscriptSearchIndex()
        index.index(try source("a", [
            prompt("typed walrus"),
            reply("assistant pelican"),
            #"{"type":"user","isMeta":true,"message":{"content":"meta heron"}}"#,
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name> stork"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"tool otter"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sidechain badger"}]}}"#,
            #"{"type":"user","origin":{"kind":"task-notification"},"message":{"content":"notified lynx"}}"#,
            #"{"type":"user","isCompactSummary":true,"message":{"content":"compacted moose"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"content":"written falcon"}}]}}"#,
        ]))
        let sessions = [session("a", minutesAgo: 1)]
        #expect(index.search("walrus", in: sessions).count == 1)
        #expect(index.search("pelican", in: sessions).count == 1)
        for word in ["heron", "stork", "otter", "badger", "lynx", "moose", "falcon"] {
            #expect(index.search(word, in: sessions).isEmpty, "\(word)")
        }
    }

    @Test func matchesCaseAndDiacriticInsensitiveAndOfWords() throws {
        var index = TranscriptSearchIndex()
        index.index(try source("a", [prompt("Fix the Café menu"), reply("ÅSA approved it")]))
        let sessions = [session("a", minutesAgo: 1)]
        #expect(index.search("cafe asa", in: sessions).count == 1)
        #expect(index.search("CAFÉ", in: sessions).count == 1)
        #expect(index.search("cafe zebra", in: sessions).isEmpty)
        #expect(index.search("   ", in: sessions).isEmpty)
    }

    @Test func newestSessionsFirstAndCapped() throws {
        var index = TranscriptSearchIndex()
        for id in ["old", "new", "mid", "unlisted"] { index.index(try source(id, [prompt("shared kestrel")])) }
        let sessions = [session("old", minutesAgo: 30), session("new", minutesAgo: 1), session("mid", minutesAgo: 10)]
        #expect(index.search("kestrel", in: sessions).map(\.id) == ["new", "mid", "old"])
        #expect(index.search("kestrel", in: sessions, limit: 2).map(\.id) == ["new", "mid"])
    }

    @Test func snippetsPreferNewestMessagesWithAllWordsAndHighlightMatches() throws {
        var index = TranscriptSearchIndex()
        let padding = String(repeating: "lorem ", count: 20)
        index.index(try source("a", [prompt("first parser note"), reply("\(padding)the Parser   streams now"), prompt("only parser here"), reply("streams alone")]))
        let snippets = try #require(index.search("parser streams", in: [session("a", minutesAgo: 1)]).first?.snippets)
        #expect(snippets.count == 2)
        #expect(snippets[0].text.hasPrefix("…"))
        #expect(snippets[0].text.contains("the Parser streams now"))
        #expect(snippets[0].highlights.map { String(snippets[0].text[$0]) } == ["Parser", "streams"])
        #expect(snippets[1].text == "streams alone")
    }

    @Test func refreshReadsOnlyAppendedLines() throws {
        var index = TranscriptSearchIndex()
        let first = try source("a", [prompt("early gannet")])
        index.index(first)
        let handle = try FileHandle(forWritingTo: first.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((prompt("later puffin") + "\n" + #"{"type":"user","message":{"content":"partial"#).utf8))
        try handle.close()
        let url = URL(filePath: first.url.path)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let grown = TranscriptSearchIndex.Source(sessionID: "a", url: url, modified: values.contentModificationDate ?? .now, size: values.fileSize ?? 0)
        #expect(index.stale([grown]).count == 1)
        index.index(grown)
        #expect(index.stale([grown]).isEmpty)
        let sessions = [session("a", minutesAgo: 1)]
        #expect(index.search("gannet puffin", in: sessions).count == 1)
        index.retain([])
        #expect(index.count == 0)
    }

    @Test func textPerSessionIsCapped() throws {
        var index = TranscriptSearchIndex(maxTextPerSession: 40)
        index.index(try source("a", [prompt(String(repeating: "a", count: 30) + " curlew"), prompt("ignored ibis")]))
        let sessions = [session("a", minutesAgo: 1)]
        #expect(index.search("curlew", in: sessions).isEmpty == false)
        #expect(index.search("ibis", in: sessions).isEmpty)
        #expect(index.textBytes <= 2 * 41)
    }

    func usage(_ id: String, at time: String, output: Int, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"2026-03-04T\#(time)Z","message":{"model":"claude-x","id":"\#(id)","content":[{"type":"tool_use","name":"Bash","input":{}}],"usage":{"input_tokens":1,"cache_creation_input_tokens":10,"cache_read_input_tokens":100,"output_tokens":\#(output)}}}"#
    }

    @Test func collectsPromptTimesAndUsageOncePerMessage() throws {
        var index = TranscriptSearchIndex(maxTextPerSession: 4)
        index.index(try source("a", [
            #"{"type":"user","timestamp":"2026-03-04T10:00:00.000Z","message":{"content":"typed prompt beyond the text cap"}}"#,
            #"{"type":"user","isMeta":true,"timestamp":"2026-03-04T10:00:01.000Z","message":{"content":"meta"}}"#,
            usage("m1", at: "10:00:02.000", output: 5),
            usage("m1", at: "10:00:03.000", output: 5),
            usage("m2", at: "10:00:04.000", output: 7),
            #"{"type":"user","timestamp":"2026-03-04T10:01:00.000Z","message":{"content":"second prompt"}}"#,
        ]))
        let activity = try #require(index.activities["a"])
        #expect(activity.prompts.count == 2)
        #expect(activity.replies.map(\.tokens.output) == [5, 7])
        #expect(activity.replies[0].tokens == TokenUsage(input: 1, output: 5, cacheRead: 100, cacheWrite: 10))
    }

    @Test func subagentUsageCountsTowardsItsSessionButIsNotSearchable() throws {
        var index = TranscriptSearchIndex()
        index.index(try source("a", [prompt("main grebe"), usage("m1", at: "10:00:00.000", output: 3)]))
        let subagent = try source("agent-1", [
            #"{"type":"user","isSidechain":true,"timestamp":"2026-03-04T10:00:01.000Z","message":{"content":"delegated tern"}}"#,
            usage("s1", at: "10:00:02.000", output: 4, sidechain: true),
        ])
        index.index(TranscriptSearchIndex.Source(sessionID: "a", url: subagent.url, modified: subagent.modified, size: subagent.size))
        #expect(index.activities["a"]?.replies.map(\.tokens.output).sorted() == [3, 4])
        #expect(index.activities["a"]?.prompts.isEmpty == true)
        let sessions = [session("a", minutesAgo: 1)]
        #expect(index.search("grebe", in: sessions).count == 1)
        #expect(index.search("tern", in: sessions).isEmpty)
    }

    @Test func appendedStreamingRecordsOfTheSameMessageCountOnce() throws {
        var index = TranscriptSearchIndex()
        let first = try source("a", [usage("m1", at: "10:00:00.000", output: 5)])
        index.index(first)
        let handle = try FileHandle(forWritingTo: first.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((usage("m1", at: "10:00:01.000", output: 5) + "\n" + usage("m2", at: "10:00:02.000", output: 6) + "\n").utf8))
        try handle.close()
        let values = try first.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        index.index(TranscriptSearchIndex.Source(sessionID: "a", url: first.url, modified: values.contentModificationDate ?? .now, size: values.fileSize ?? 0))
        #expect(index.activities["a"]?.replies.map(\.tokens.output) == [5, 6])
    }
}
