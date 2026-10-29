import Foundation

public struct PullRequestLink: Sendable, Hashable {
    public let number: Int
    public let url: URL
    public let repository: String

    public init(number: Int, url: URL, repository: String) {
        self.number = number
        self.url = url
        self.repository = repository
    }
}

public struct SessionSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let cwd: String
    public let title: String
    public let lastActivity: Date
    public let lastPrompt: Date
    public let branch: String?
    public let pullRequest: PullRequestLink?

    public init(id: String, cwd: String, title: String, lastActivity: Date, lastPrompt: Date? = nil, branch: String? = nil, pullRequest: PullRequestLink? = nil) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.lastActivity = lastActivity
        self.lastPrompt = lastPrompt ?? lastActivity
        self.branch = branch
        self.pullRequest = pullRequest
    }
}

public enum Transcript {
    static let headBytes = 32 * 1024
    static let tailBytes = 64 * 1024
    static let promptScanBytes = 1024 * 1024
    static let maxTitleLength = 120

    public static func summary(of url: URL, after known: (size: Int, lastPrompt: Date)? = nil) -> SessionSummary? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        let tailOffset = max(0, size - tailBytes)
        guard (try? handle.seek(toOffset: UInt64(tailOffset))) != nil else { return nil }
        let tail = (try? handle.readToEnd()) ?? Data()
        let tailRecords = records(in: tail, dropFirst: tailOffset > 0, dropLast: false)
        let known = known.flatMap { $0.size <= size ? $0 : nil }
        let earlierPrompt = tailOffset == 0 || lastPrompt(in: tailRecords) != nil ? nil : lastPrompt(
            in: handle,
            before: tailOffset + (tail.firstIndex(of: UInt8(ascii: "\n")).map { $0 - tail.startIndex } ?? tail.count),
            floor: max(tailOffset - promptScanBytes, (known?.size ?? 0) - tailBytes, 0)
        ) ?? known?.lastPrompt
        return summary(
            id: url.deletingPathExtension().lastPathComponent,
            folder: url.deletingLastPathComponent().lastPathComponent,
            modified: modified,
            head: records(in: head, dropFirst: false, dropLast: size > head.count),
            tail: tailRecords,
            earlierPrompt: earlierPrompt
        )
    }

    static func summary(id: String, folder: String, modified: Date, head: [Record], tail: [Record], earlierPrompt: Date? = nil) -> SessionSummary? {
        let relocated = tail.last { $0.relocatedCwd != nil }?.relocatedCwd
        let inFolder = (tail.reversed() + head.reversed()).lazy.compactMap(\.cwd).first { cwd in
            let slug = cwd.utf16.map { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ? $0 : 45 }
            return String(decoding: slug, as: UTF16.self) == folder
        }
        guard let cwd = relocated ?? inFolder ?? head.first(where: { $0.cwd != nil })?.cwd ?? tail.first(where: { $0.cwd != nil })?.cwd else { return nil }
        let titleKeys: [KeyPath<Record, String?>] = [\.customTitle, \.aiTitle, \.summary, \.agentName]
        let recordedTitle = titleKeys.lazy.compactMap { key in tail.last { $0[keyPath: key] != nil }?[keyPath: key] }.first
        guard let title = recordedTitle ?? head.lazy.compactMap(\.promptText).first else { return nil }
        let oneLine = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let branch = tail.last { $0.gitBranch != nil }?.gitBranch
        let link = tail.last { $0.type == "pr-link" && $0.prNumber != nil }
        return SessionSummary(
            id: id,
            cwd: cwd,
            title: String(oneLine.prefix(maxTitleLength)),
            lastActivity: lastConversation(in: tail) ?? lastConversation(in: head) ?? modified,
            lastPrompt: lastPrompt(in: tail) ?? earlierPrompt ?? lastPrompt(in: head) ?? head.lazy.compactMap(\.date).first ?? modified,
            branch: branch == "HEAD" || branch?.isEmpty == true ? nil : branch,
            pullRequest: link.flatMap { link in
                guard let number = link.prNumber, let url = link.prUrl.flatMap(URL.init(string:)), let repository = link.prRepository else { return nil }
                return PullRequestLink(number: number, url: url, repository: repository)
            }
        )
    }

    static func lastConversation(in records: [Record]) -> Date? {
        records.last { $0.isConversation && $0.timestamp != nil }?.date
    }

    static func lastPrompt(in records: [Record]) -> Date? {
        records.last { $0.typedPrompt != nil && $0.timestamp != nil }?.date
    }

    static func lastPrompt(in handle: FileHandle, before end: Int, floor: Int) -> Date? {
        let decoder = JSONDecoder()
        var end = end
        var carry = Data()
        while end > floor {
            let start = max(floor, end - tailBytes)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil, let chunk = try? handle.read(upToCount: end - start) else { return nil }
            let lines = (chunk + carry).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            carry = start > floor ? Data(lines.first ?? Data()) : Data()
            let candidates = lines.dropFirst(start > floor ? 1 : 0).filter { line in
                line.range(of: Data(#""type":"user""#.utf8)) != nil
                    && line.range(of: Data(#""type":"tool_result""#.utf8)) == nil
                    && line.range(of: Data(#""isCompactSummary":true"#.utf8)) == nil
            }
            if let date = lastPrompt(in: candidates.compactMap { try? decoder.decode(Record.self, from: Data($0)) }) { return date }
            end = start
        }
        return nil
    }

    static func records(in data: Data, dropFirst: Bool, dropLast: Bool) -> [Record] {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let complete = lines.dropFirst(dropFirst ? 1 : 0).dropLast(dropLast ? 1 : 0)
        let decoder = JSONDecoder()
        return complete.compactMap { try? decoder.decode(Record.self, from: Data($0)) }
    }
}

struct Record: Decodable {
    struct Message: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        struct Usage: Decodable {
            let input: Int?
            let output: Int?
            let cacheRead: Int?
            let cacheWrite: Int?

            enum CodingKeys: String, CodingKey {
                case input = "input_tokens", output = "output_tokens", cacheRead = "cache_read_input_tokens", cacheWrite = "cache_creation_input_tokens"
            }
        }

        let content: [Block]
        let id: String?
        let usage: Usage?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            usage = try? container.decode(Usage.self, forKey: .usage)
            if let text = try? container.decode(String.self, forKey: .content) {
                content = [Block(type: "text", text: text)]
            } else {
                content = (try? container.decode([Block].self, forKey: .content)) ?? []
            }
        }

        enum CodingKeys: String, CodingKey { case content, id, usage }
    }

    let type: String?
    let cwd: String?
    let relocatedCwd: String?
    let gitBranch: String?
    let timestamp: String?
    let prNumber: Int?
    let prUrl: String?
    let prRepository: String?
    let customTitle: String?
    let aiTitle: String?
    let agentName: String?
    let summary: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    let isCompactSummary: Bool?
    let origin: Origin?
    let message: Message?

    struct Origin: Decodable {
        let kind: String?
    }

    var date: Date? {
        timestamp.flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
    }

    var isConversation: Bool {
        (type == "assistant" && isSidechain != true) || promptText != nil
    }

    var typedPrompt: String? {
        origin.map { $0.kind == "human" } ?? true && isCompactSummary != true ? promptText : nil
    }

    var promptText: String? {
        guard type == "user", isMeta != true, isSidechain != true,
              let text = message?.content.first(where: { $0.type == "text" })?.text,
              !text.contains("<command-name>"), !text.contains("<local-command"), !text.contains("<bash-stdout>"), !text.hasPrefix("Caveat:")
        else { return nil }
        let stripped = text.replacing(/<[^>]*>/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}
