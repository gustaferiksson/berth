import Foundation

public enum CodexRollout {
    static let headBytes = 256 * 1024
    static let tailBytes = 256 * 1024
    static let maxTailBytes = 8 * 1024 * 1024
    static let maxTitleLength = 120
    static let excludedOriginators: Set<String> = ["codex_exec", "Claude Code"]
    static let keywords = ["session_meta", "turn_context", "user_message", "agent_message", "token_count", "compacted"].map { Data($0.utf8) }

    public static func summary(of url: URL, name: String? = nil) -> SessionSummary? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }

        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        let headRecords = records(in: head, dropFirst: false, dropLast: size > head.count)
        guard let meta = headRecords.first(where: { $0.type == "session_meta" })?.payload, isInteractive(meta),
              let tailRecords = tail(of: handle, size: size)
        else { return nil }

        let firstPrompt = headRecords.lazy.compactMap(\.prompt).first
        guard let title = name.flatMap({ $0.isEmpty ? nil : $0 }) ?? firstPrompt else { return nil }

        let id = meta.id ?? String(url.deletingPathExtension().lastPathComponent.suffix(36))
        let started = meta.timestamp.flatMap(date)
        let cwd = tailRecords.last { $0.type == "turn_context" && $0.payload?.cwd != nil }?.payload?.cwd ?? meta.cwd
        guard let cwd else { return nil }

        let model = (tailRecords + headRecords).last { $0.type == "turn_context" && $0.payload?.model != nil }?.payload?.model
        let branch = meta.git?.branch.flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
        let lastTyped = tailRecords.last { $0.prompt != nil }?.timestamp.flatMap(date)
        let lastConversation = tailRecords.last { $0.isConversation }?.timestamp.flatMap(date)
        let tokens = tailRecords.lastIndex { $0.payload?.info?.lastInput != nil }
        let compaction = tailRecords.lastIndex { $0.type == "compacted" }
        let context: SessionContext? = if let tokens, let model, tokens > compaction ?? -1, let input = tailRecords[tokens].payload?.info?.lastInput {
            SessionContext(model: model, tokens: input, window: tailRecords[tokens].payload?.info?.window, modelName: model)
        } else {
            nil
        }
        return SessionSummary(
            id: id,
            cwd: cwd,
            title: String(title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maxTitleLength)),
            lastActivity: lastConversation ?? headRecords.last { $0.isConversation }?.timestamp.flatMap(date) ?? modified,
            lastPrompt: lastTyped ?? headRecords.last { $0.prompt != nil }?.timestamp.flatMap(date) ?? started ?? modified,
            lastTypedPrompt: lastTyped,
            branch: branch,
            context: context,
            agent: .codex,
            startedAt: started
        )
    }

    static func isInteractive(_ meta: Record.Payload) -> Bool {
        (meta.threadSource ?? "user") == "user" && meta.source != "exec" && !excludedOriginators.contains(meta.originator ?? "")
    }

    static func date(_ timestamp: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)
    }

    static func tail(of handle: FileHandle, size: Int) -> [Record]? {
        var window = tailBytes
        while true {
            let offset = max(0, size - window)
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }

            let found = records(in: (try? handle.readToEnd()) ?? Data(), dropFirst: offset > 0, dropLast: false)
            if offset == 0 || window >= maxTailBytes || found.contains(where: { $0.prompt != nil }) && found.contains(where: { $0.type == "turn_context" }) { return found }

            window *= 2
        }
    }

    static func records(in data: Data, dropFirst: Bool, dropLast: Bool) -> [Record] {
        let decoder = JSONDecoder()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        return lines.dropFirst(dropFirst ? 1 : 0).dropLast(dropLast ? 1 : 0).compactMap { line in
            guard keywords.contains(where: { line.range(of: $0) != nil }) else { return nil }

            return try? decoder.decode(Record.self, from: Data(line))
        }
    }

    struct Git: Decodable {
        let branch: String?
    }

    struct Info: Decodable {
        enum CodingKeys: String, CodingKey {
            case window = "model_context_window", usage = "last_token_usage"
        }

        enum UsageKeys: String, CodingKey { case input = "input_tokens" }

        let lastInput: Int?
        let window: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            window = try? container.decode(Int.self, forKey: .window)
            lastInput = (try? container.nestedContainer(keyedBy: UsageKeys.self, forKey: .usage))
                .flatMap { try? $0.decode(Int.self, forKey: .input) }
        }
    }

    struct Record: Decodable {
        struct Payload: Decodable {
            let type: String?
            let id: String?
            let timestamp: String?
            let cwd: String?
            let originator: String?
            let threadSource: String?
            let source: String?
            let git: CodexRollout.Git?
            let message: String?
            let model: String?
            let info: CodexRollout.Info?

            enum CodingKeys: String, CodingKey {
                case type, id, timestamp, cwd, originator, source, git, message, model, info
                case threadSource = "thread_source"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decode(String.self, forKey: .type)
                id = try? container.decode(String.self, forKey: .id)
                timestamp = try? container.decode(String.self, forKey: .timestamp)
                cwd = try? container.decode(String.self, forKey: .cwd)
                originator = try? container.decode(String.self, forKey: .originator)
                threadSource = try? container.decode(String.self, forKey: .threadSource)
                source = try? container.decode(String.self, forKey: .source)
                git = try? container.decode(CodexRollout.Git.self, forKey: .git)
                message = try? container.decode(String.self, forKey: .message)
                model = try? container.decode(String.self, forKey: .model)
                info = try? container.decode(CodexRollout.Info.self, forKey: .info)
            }
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?

        var prompt: String? {
            guard type == "event_msg", payload?.type == "user_message",
                  let text = payload?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }

            return text
        }

        var isConversation: Bool {
            type == "event_msg" && (payload?.type == "user_message" || payload?.type == "agent_message")
        }
    }
}

public struct CodexIndex: Sendable {
    struct Entry: Sendable {
        let modified: Date
        let size: Int
        let name: String?
        let summary: SessionSummary?
    }

    private struct IndexLine: Decodable {
        let id: String
        let threadName: String?

        enum CodingKeys: String, CodingKey {
            case id, threadName = "thread_name"
        }
    }

    public let root: URL
    private var entries: [String: Entry] = [:]

    public init(root: URL) {
        self.root = root
    }

    public static func home(environment: [String: String], user: URL) -> URL {
        environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) } ?? user.appending(path: ".codex")
    }

    public mutating func refresh() -> [SessionSummary] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let names = Self.names(in: root.appending(path: "session_index.jsonl"))
        let files = FileManager.default.enumerator(at: root.appending(path: "sessions"), includingPropertiesForKeys: keys)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") } ?? []
        let next = files.reduce(into: [String: Entry]()) { result, file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, let size = values.fileSize
            else { return }

            let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
            let name = names[id]
            if let cached = entries[file.path], cached.modified == modified, cached.size == size, cached.name == name {
                result[file.path] = cached
                return
            }
            result[file.path] = Entry(modified: modified, size: size, name: name, summary: CodexRollout.summary(of: file, name: name) ?? entries[file.path]?.summary)
        }
        entries = next
        return next.values.compactMap(\.summary)
    }

    static func names(in url: URL) -> [String: String] {
        let decoder = JSONDecoder()
        let lines = ((try? Data(contentsOf: url)) ?? Data()).split(separator: UInt8(ascii: "\n"))
        return lines.reduce(into: [:]) { names, line in
            guard let entry = try? decoder.decode(IndexLine.self, from: Data(line)) else { return }

            names[entry.id] = entry.threadName
        }
    }
}
