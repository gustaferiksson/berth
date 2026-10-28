import Foundation

public struct SearchSnippet: Sendable, Hashable {
    public let text: String
    public let highlights: [Range<String.Index>]
}

public struct SearchHit: Sendable, Hashable, Identifiable {
    public let session: SessionSummary
    public let snippets: [SearchSnippet]

    public var id: String { session.id }
}

public struct TranscriptSearchIndex: Sendable {
    public struct Source: Sendable {
        public let sessionID: String
        public let url: URL
        public let modified: Date
        public let size: Int
    }

    struct Document: Sendable {
        let path: String
        let modified: Date
        let size: Int
        let offset: UInt64
        let text: String
        let folded: String
    }

    static let separator: Character = "\u{1E}"
    static let snippetLead = 40
    static let snippetLength = 160

    public let maxTextPerSession: Int
    private var documents: [String: Document] = [:]

    public init(maxTextPerSession: Int = 512 * 1024) {
        self.maxTextPerSession = maxTextPerSession
    }

    public var textBytes: Int {
        documents.values.reduce(0) { $0 + $1.text.utf8.count + $1.folded.utf8.count }
    }

    public var count: Int { documents.count }

    public func stale(_ sources: [Source]) -> [Source] {
        sources.filter { source in
            guard let document = documents[source.sessionID] else { return true }
            return document.path != source.url.path || document.modified != source.modified || document.size != source.size
        }
    }

    public mutating func retain(_ sources: [Source]) {
        let kept = Set(sources.map(\.sessionID))
        documents = documents.filter { kept.contains($0.key) }
    }

    public mutating func index(_ source: Source) {
        let previous = documents[source.sessionID].flatMap { $0.path == source.url.path && $0.size <= source.size ? $0 : nil }
        let (messages, offset) = Self.messages(in: source.url, from: previous?.offset ?? 0, budget: maxTextPerSession - (previous?.text.utf8.count ?? 0))
        let added = messages.map { String($0.filter { $0 != Self.separator }) }.joined(separator: String(Self.separator))
        let text = [previous?.text ?? "", added].filter { !$0.isEmpty }.joined(separator: String(Self.separator))
        documents[source.sessionID] = Document(
            path: source.url.path,
            modified: source.modified,
            size: source.size,
            offset: offset,
            text: text,
            folded: text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        )
    }

    public func search(_ query: String, in sessions: [SessionSummary], limit: Int = 50) -> [SearchHit] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let needles = words.map { Array($0.utf8) }
        let contains = { (text: Substring, needle: [UInt8]) in text.utf8.withContiguousStorageIfAvailable { memmem($0.baseAddress, $0.count, needle, needle.count) != nil } ?? false }
        let matching = sessions.sorted { $0.lastActivity > $1.lastActivity }.lazy.compactMap { session -> (SessionSummary, Document)? in
            guard let document = self.documents[session.id], needles.allSatisfy({ contains(Substring(document.folded), $0) }) else { return nil }
            return (session, document)
        }
        return matching.prefix(limit).map { session, document in
            let messages = document.text.utf8.split(separator: 0x1E, omittingEmptySubsequences: false).map(Substring.init)
            let folded = document.folded.utf8.split(separator: 0x1E, omittingEmptySubsequences: false).map(Substring.init)
            let newestFirst = folded.indices.reversed()
            let full = Array(newestFirst.lazy.filter { index in needles.allSatisfy { contains(folded[index], $0) } }.prefix(2))
            let partial = newestFirst.lazy.filter { index in !full.contains(index) && needles.contains { contains(folded[index], $0) } }.prefix(2 - full.count)
            return SearchHit(session: session, snippets: (full + partial).compactMap { Self.snippet(of: String(messages[$0]), words: words) })
        }
    }

    static func snippet(of message: String, words: [String]) -> SearchSnippet? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let first = words.lazy.compactMap({ message.range(of: $0, options: options) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let start = message.index(first.lowerBound, offsetBy: -snippetLead, limitedBy: message.startIndex) ?? message.startIndex
        let end = message.index(start, offsetBy: snippetLength, limitedBy: message.endIndex) ?? message.endIndex
        let window = message[start..<end].replacing(/\s+/, with: " ").replacing(/\*\*|`/, with: "")
        let text = (start > message.startIndex ? "…" : "") + window + (end < message.endIndex ? "…" : "")
        var highlights: [Range<String.Index>] = []
        for word in words {
            var start = text.startIndex
            while let range = text.range(of: word, options: options, range: start..<text.endIndex) {
                highlights.append(range)
                start = range.upperBound
            }
        }
        highlights.sort { $0.lowerBound < $1.lowerBound }
        return SearchSnippet(text: text, highlights: highlights)
    }

    static func messages(in url: URL, from offset: UInt64, budget: Int) -> (messages: [String], offset: UInt64) {
        guard budget > 0, let handle = try? FileHandle(forReadingFrom: url), (try? handle.seek(toOffset: offset)) != nil else { return ([], offset) }
        defer { try? handle.close() }
        var messages: [String] = []
        var used = 0
        var consumed = offset
        var pending = Data()
        let decoder = JSONDecoder()
        while used < budget, let chunk = autoreleasepool(invoking: { try? handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            pending.append(chunk)
            let (lines, complete) = pending.withUnsafeBytes { buffer -> ([Data], Int) in
                guard let base = buffer.baseAddress else { return ([], 0) }
                var lines: [Data] = []
                var start = 0
                while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
                    let end = base.distance(to: newline)
                    let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                    if isCandidate(line) { lines.append(Data(line)) }
                    start = end + 1
                }
                return (lines, start)
            }
            consumed += UInt64(complete)
            pending = Data(pending.dropFirst(complete))
            for line in lines where used < budget {
                guard let record = try? decoder.decode(Record.self, from: line) else { continue }
                let texts = record.typedPrompt.map { [$0] } ?? (record.type == "assistant" ? (record.message?.content ?? []).compactMap { $0.type == "text" ? $0.text : nil } : [])
                for text in texts where !text.allSatisfy(\.isWhitespace) && used < budget {
                    let kept = String(decoding: text.utf8.prefix(budget - used), as: UTF8.self)
                    messages.append(kept)
                    used += kept.utf8.count
                }
            }
        }
        return (messages, consumed)
    }

    static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        let has = { (pattern: StaticString) in memmem(line.baseAddress, line.count, pattern.utf8Start, pattern.utf8CodeUnitCount) != nil }
        guard !has(#""isSidechain":true"#), !has(#""isMeta":true"#) else { return false }
        if has(#""type":"assistant""#) { return has(#""type":"text""#) }
        return has(#""type":"user""#) && !has(#""type":"tool_result""#)
    }
}
