import Foundation

public struct SessionContext: Sendable, Hashable {
    public let model: String
    public let tokens: Int
    public var window: Int?
    public var modelName: String?

    public init(model: String, tokens: Int, window: Int? = nil, modelName: String? = nil) {
        self.model = model
        self.tokens = tokens
        self.window = window
        self.modelName = modelName
    }
}

public struct PullRequestLink: Sendable, Hashable {
    public let repository: String
    public let number: Int

    public init(repository: String, number: Int) {
        self.repository = repository
        self.number = number
    }
}

public struct SessionSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let cwd: String
    public let title: String
    public let lastActivity: Date
    public let lastPrompt: Date
    public let lastTypedPrompt: Date?
    public let branch: String?
    public let branches: [String]
    public let pullRequests: [PullRequestLink]
    public let issueRefs: [IssueRef]
    public let continuedIn: String?
    public let originalCwd: String?
    public var checkout: String
    public var context: SessionContext?

    public init(id: String, cwd: String, title: String, lastActivity: Date, lastPrompt: Date? = nil, lastTypedPrompt: Date? = nil, branch: String? = nil, branches: [String]? = nil, pullRequests: [PullRequestLink] = [], issueRefs: [IssueRef] = [], continuedIn: String? = nil, originalCwd: String? = nil, context: SessionContext? = nil) {
        self.id = id
        self.cwd = cwd
        checkout = cwd
        self.title = title
        self.lastActivity = lastActivity
        self.lastPrompt = lastPrompt ?? lastActivity
        self.lastTypedPrompt = lastTypedPrompt
        self.branch = branch
        self.branches = branches ?? branch.map { [$0] } ?? []
        self.pullRequests = pullRequests
        self.issueRefs = issueRefs
        self.continuedIn = continuedIn
        self.originalCwd = originalCwd
        self.context = context
    }
}

public enum Transcript {
    static let headBytes = 32 * 1024
    static let tailBytes = 64 * 1024
    static let maxTailBytes = 8 * 1024 * 1024
    static let maxTitleLength = 120

    public static func summary(of url: URL, after known: (size: Int, lastPrompt: Date, branches: [String], pullRequests: [PullRequestLink], issueRefs: [IssueRef], context: SessionContext?)? = nil) -> SessionSummary? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }

        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        guard let (tailOffset, firstLineEnd, tailRecords) = tail(of: handle, size: size) else { return nil }

        let known = known.flatMap { $0.size <= size ? $0 : nil }
        let earlierPrompt = tailOffset == 0 || lastPrompt(in: tailRecords) != nil ? nil : lastPrompt(
            in: handle,
            before: firstLineEnd,
            floor: max((known?.size ?? 0) - tailBytes, 0)
        ) ?? known?.lastPrompt
        return summary(
            id: url.deletingPathExtension().lastPathComponent,
            folder: url.deletingLastPathComponent().lastPathComponent,
            modified: modified,
            head: records(in: head, dropFirst: false, dropLast: size > head.count),
            tail: tailRecords,
            earlierPrompt: earlierPrompt,
            earlierBranches: known?.branches ?? [],
            earlierPullRequests: known?.pullRequests ?? [],
            earlierIssueRefs: known?.issueRefs ?? [],
            earlierContext: known.flatMap { tailOffset <= $0.size ? $0.context : nil }
        )
    }

    static func summary(id: String, folder: String, modified: Date, head: [Record], tail: [Record], earlierPrompt: Date? = nil, earlierBranches: [String] = [], earlierPullRequests: [PullRequestLink] = [], earlierIssueRefs: [IssueRef] = [], earlierContext: SessionContext? = nil) -> SessionSummary? {
        let relocated = tail.last { $0.relocatedCwd != nil }?.relocatedCwd
        let worktreeState = tail.lastIndex { $0.type == "worktree-state" }
        let entered = tail.last { $0.worktreeSession != nil }?.worktreeSession
        let worktree = worktreeState.flatMap { index in tail[index].worktreeSession?.worktreePath ?? tail[(index + 1)...].first { $0.cwd != nil }?.cwd ?? entered?.originalCwd }
        let inFolder = (tail.reversed() + head.reversed()).lazy.compactMap(\.cwd).first { cwd in
            let slug = cwd.utf16.map { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ? $0 : 45 }
            return String(decoding: slug, as: UTF16.self) == folder
        }
        guard let cwd = relocated ?? worktree ?? inFolder ?? head.first(where: { $0.cwd != nil })?.cwd ?? tail.first(where: { $0.cwd != nil })?.cwd else { return nil }

        let titleKeys: [KeyPath<Record, String?>] = [\.customTitle, \.aiTitle, \.summary, \.agentName]
        let recordedTitle = titleKeys.lazy.compactMap { key in tail.last { $0[keyPath: key] != nil }?[keyPath: key] }.first
        guard let title = recordedTitle ?? head.lazy.compactMap(\.promptText).first else { return nil }

        let oneLine = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let branch = tail.last { $0.gitBranch != nil }?.gitBranch
        let continuedAt = tail.lastIndex { $0.continuedInSessionId != nil }
        let continuedIn = continuedAt.flatMap { index in tail[index...].contains(where: \.isConversation) ? nil : tail[index].continuedInSessionId }
        let reply = tail.lastIndex { record in
            let usage = record.message?.usage
            return record.type == "assistant" && record.isSidechain != true && record.message?.model.map { $0 != "<synthetic>" } == true
                && (usage?.input ?? 0) + (usage?.cacheRead ?? 0) + (usage?.cacheWrite ?? 0) > 0
        }
        let compaction = tail.lastIndex { $0.subtype == "compact_boundary" && $0.isSidechain != true }
        let context: SessionContext? = if let compaction, compaction > reply ?? -1 {
            nil
        } else if let reply, let message = tail[reply].message, let model = message.model {
            SessionContext(model: model, tokens: (message.usage?.input ?? 0) + (message.usage?.cacheRead ?? 0) + (message.usage?.cacheWrite ?? 0))
        } else {
            earlierContext
        }
        let recordedBranches = tail.reversed().compactMap(\.gitBranch) + earlierBranches + head.reversed().compactMap(\.gitBranch)
        return SessionSummary(
            id: id,
            cwd: cwd,
            title: String(oneLine.prefix(maxTitleLength)),
            lastActivity: lastConversation(in: tail) ?? lastConversation(in: head) ?? modified,
            lastPrompt: lastPrompt(in: tail) ?? earlierPrompt ?? lastPrompt(in: head) ?? head.lazy.compactMap(\.date).first ?? modified,
            lastTypedPrompt: tail.last { $0.typedPrompt != nil && $0.timestamp != nil }?.date,
            branch: branch == "HEAD" || branch?.isEmpty == true ? nil : branch,
            branches: recordedBranches.reduce(into: []) { branches, branch in
                if branch != "HEAD", !branch.isEmpty, !branches.contains(branch) { branches.append(branch) }
            },
            pullRequests: (tail.reversed().compactMap(\.pullRequestLink) + earlierPullRequests + head.reversed().compactMap(\.pullRequestLink)).reduce(into: []) { links, link in
                if !links.contains(link) { links.append(link) }
            },
            issueRefs: (head.compactMap(\.typedPrompt) + tail.compactMap(\.typedPrompt)).flatMap(IssueRef.typed).reduce(into: earlierIssueRefs) { refs, ref in
                if !refs.contains(ref) { refs.append(ref) }
            },
            continuedIn: continuedIn,
            originalCwd: entered?.originalCwd,
            context: context
        )
    }

    static func tail(of handle: FileHandle, size: Int) -> (offset: Int, firstLineEnd: Int, records: [Record])? {
        var window = tailBytes
        while true {
            let offset = max(0, size - window)
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }

            let data = (try? handle.readToEnd()) ?? Data()
            let records = records(in: data, dropFirst: offset > 0, dropLast: false)
            let hasTitle = records.contains { $0.customTitle != nil || $0.aiTitle != nil || $0.summary != nil || $0.agentName != nil }
            if offset == 0 || window >= maxTailBytes || hasTitle && lastConversation(in: records) != nil {
                let newline = data.withUnsafeBytes { buffer in buffer.baseAddress.flatMap { base in memchr(base, 0x0A, buffer.count).map { base.distance(to: $0) } } }
                return (offset, offset + (newline ?? 0), records)
            }
            window *= 2
        }
    }

    static func lastConversation(in records: [Record]) -> Date? {
        records.last { $0.isConversation && $0.timestamp != nil }?.date
    }

    static func lastPrompt(in records: [Record]) -> Date? {
        records.last { ($0.typedPrompt != nil || $0.isQueuedPrompt) && $0.timestamp != nil }?.date
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
                line.range(of: Data(#""type":"queued_command""#.utf8)) != nil
                    || line.range(of: Data(#""type":"user""#.utf8)) != nil
                    && line.range(of: Data(#""type":"tool_result""#.utf8)) == nil
                    && line.range(of: Data(#""isCompactSummary":true"#.utf8)) == nil
            }
            if let date = lastPrompt(in: candidates.compactMap { try? decoder.decode(Record.self, from: Data($0)) }) { return date }
            end = start
        }
        return nil
    }

    static func records(in data: Data, dropFirst: Bool, dropLast: Bool) -> [Record] {
        let decoder = JSONDecoder()
        return data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return [] }

            var lines: [UnsafeRawBufferPointer] = []
            var start = 0
            while start < buffer.count {
                let end = memchr(base + start, 0x0A, buffer.count - start).map { base.distance(to: $0) } ?? buffer.count
                if end > start { lines.append(UnsafeRawBufferPointer(rebasing: buffer[start..<end])) }
                start = end + 1
            }
            return lines.dropFirst(dropFirst ? 1 : 0).dropLast(dropLast ? 1 : 0).compactMap { line in
                let has = { (pattern: StaticString) in memmem(line.baseAddress, line.count, pattern.utf8Start, pattern.utf8CodeUnitCount) != nil }
                guard !line.starts(with: #"{"type":"api-request"#.utf8), !has(#""type":"tool_result""#), !has(#""type":"attachment""#) || has(#""type":"queued_command""#) else { return nil }

                return try? decoder.decode(Record.self, from: Data(line))
            }
        }
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
        let model: String?
        let usage: Usage?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            model = try? container.decode(String.self, forKey: .model)
            usage = try? container.decode(Usage.self, forKey: .usage)
            if let text = try? container.decode(String.self, forKey: .content) {
                content = [Block(type: "text", text: text)]
            } else {
                content = (try? container.decode([Block].self, forKey: .content)) ?? []
            }
        }

        enum CodingKeys: String, CodingKey { case content, id, model, usage }
    }

    let type: String?
    let subtype: String?
    let cwd: String?
    let relocatedCwd: String?
    let worktreeSession: WorktreeSession?
    let continuedInSessionId: String?
    let gitBranch: String?
    let prRepository: String?
    let prNumber: Int?
    let timestamp: String?
    let customTitle: String?
    let aiTitle: String?
    let agentName: String?
    let summary: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    let isCompactSummary: Bool?
    let origin: Origin?
    let message: Message?
    let attachment: Attachment?
    let operation: String?
    let content: String?

    struct Origin: Decodable {
        let kind: String?
    }

    struct WorktreeSession: Decodable {
        let originalCwd: String?
        let worktreePath: String?
    }

    struct Attachment: Decodable {
        let type: String?
        let commandMode: String?
        let origin: Origin?
        let humanTurn: Bool?
    }

    var date: Date? {
        timestamp.flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
    }

    var pullRequestLink: PullRequestLink? {
        guard type == "pr-link", let prRepository, let prNumber else { return nil }

        return PullRequestLink(repository: prRepository, number: prNumber)
    }

    var isConversation: Bool {
        (type == "assistant" && isSidechain != true) || promptText != nil || isQueuedPrompt
    }

    var isQueuedPrompt: Bool {
        type == "attachment" && isSidechain != true && attachment?.type == "queued_command" && attachment?.commandMode == "prompt"
            && (attachment?.origin?.kind == "human" || attachment?.humanTurn == true)
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
