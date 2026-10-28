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
        let sessionID: String
        let modified: Date
        let size: Int
        let offset: UInt64
        let text: String
        let folded: String
        let activity: SessionActivity
        let lastMessageID: String?
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
            guard let document = documents[source.url.path] else { return true }
            return document.sessionID != source.sessionID || document.modified != source.modified || document.size != source.size
        }
    }

    public mutating func retain(_ sources: [Source]) {
        let kept = Set(sources.map(\.url.path))
        documents = documents.filter { kept.contains($0.key) }
    }

    public mutating func index(_ source: Source) {
        let previous = documents[source.url.path].flatMap { $0.sessionID == source.sessionID && $0.size <= source.size ? $0 : nil }
        let scan = Self.scan(source.url, from: previous?.offset ?? 0, budget: maxTextPerSession - (previous?.text.utf8.count ?? 0), lastMessageID: previous?.lastMessageID)
        let added = scan.messages.map { String($0.filter { $0 != Self.separator }) }.joined(separator: String(Self.separator))
        let text = [previous?.text ?? "", added].filter { !$0.isEmpty }.joined(separator: String(Self.separator))
        documents[source.url.path] = Document(
            sessionID: source.sessionID,
            modified: source.modified,
            size: source.size,
            offset: scan.offset,
            text: text,
            folded: [previous?.folded ?? "", added.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)].filter { !$0.isEmpty }.joined(separator: String(Self.separator)),
            activity: SessionActivity(prompts: (previous?.activity.prompts ?? []) + scan.activity.prompts, replies: (previous?.activity.replies ?? []) + scan.activity.replies),
            lastMessageID: scan.lastMessageID
        )
    }

    public var activities: [String: SessionActivity] {
        documents.values.reduce(into: [:]) { result, document in
            result[document.sessionID, default: SessionActivity()].prompts += document.activity.prompts
            result[document.sessionID, default: SessionActivity()].replies += document.activity.replies
        }
    }

    public func search(_ query: String, in sessions: [SessionSummary], limit: Int = 50) -> [SearchHit] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let needles = words.map { Array($0.utf8) }
        let contains = { (text: Substring, needle: [UInt8]) in text.utf8.withContiguousStorageIfAvailable { memmem($0.baseAddress, $0.count, needle, needle.count) != nil } ?? false }
        let transcripts = Dictionary(documents.values.filter { !$0.text.isEmpty }.map { ($0.sessionID, $0) }) { first, _ in first }
        let matching = sessions.sorted { $0.lastActivity > $1.lastActivity }.lazy.compactMap { session -> (SessionSummary, Document)? in
            guard let document = transcripts[session.id], needles.allSatisfy({ contains(Substring(document.folded), $0) }) else { return nil }
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

    static func scan(_ url: URL, from offset: UInt64, budget: Int, lastMessageID: String?) -> (messages: [String], activity: SessionActivity, lastMessageID: String?, offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url), (try? handle.seek(toOffset: offset)) != nil else { return ([], SessionActivity(), lastMessageID, offset) }
        defer { try? handle.close() }
        var messages: [String] = []
        var activity = SessionActivity()
        var lastMessageID = lastMessageID
        var used = 0
        var consumed = offset
        var pending = Data()
        let decoder = JSONDecoder()
        let timestamps = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        while let chunk = autoreleasepool(invoking: { try? handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
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
            for line in lines {
                guard let record = try? decoder.decode(Record.self, from: line) else { continue }
                let messageID = record.message?.id
                if let usage = record.message?.usage, record.type == "assistant", messageID == nil || messageID != lastMessageID,
                   let date = record.timestamp.flatMap({ try? timestamps.parse($0) }) {
                    lastMessageID = messageID
                    activity.replies.append(SessionActivity.Reply(date: date, tokens: TokenUsage(input: usage.input ?? 0, output: usage.output ?? 0, cacheRead: usage.cacheRead ?? 0, cacheWrite: usage.cacheWrite ?? 0)))
                }
                if record.typedPrompt != nil, let date = record.timestamp.flatMap({ try? timestamps.parse($0) }) { activity.prompts.append(date) }
                guard record.isSidechain != true else { continue }
                let texts = record.typedPrompt.map { [$0] } ?? (record.type == "assistant" ? (record.message?.content ?? []).compactMap { $0.type == "text" ? $0.text : nil } : [])
                for text in texts where !text.allSatisfy(\.isWhitespace) && used < budget {
                    let kept = String(decoding: text.utf8.prefix(budget - used), as: UTF8.self)
                    messages.append(kept)
                    used += kept.utf8.count
                }
            }
        }
        return (messages, activity, lastMessageID, consumed)
    }

    static func isCandidate(_ line: UnsafeRawBufferPointer) -> Bool {
        let has = { (pattern: StaticString) in memmem(line.baseAddress, line.count, pattern.utf8Start, pattern.utf8CodeUnitCount) != nil }
        if has(#""type":"user""#) { return !has(#""type":"tool_result""#) && !has(#""isSidechain":true"#) && !has(#""isMeta":true"#) }
        guard has(#""type":"assistant""#) else { return false }
        return has(#""usage":{"#) || has(#""type":"text""#) && !has(#""isSidechain":true"#)
    }
}
