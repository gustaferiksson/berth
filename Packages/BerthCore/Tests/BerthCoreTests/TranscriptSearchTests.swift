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
}
