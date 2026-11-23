import Foundation

public enum CodexRollout {
    static let headBytes = 256 * 1024
    static let tailBytes = 256 * 1024
    static let maxTailBytes = 8 * 1024 * 1024
    static let maxTitleLength = 120
    static let excludedOriginators: Set<String> = ["codex_exec", "Claude Code"]
    static let summaryKeywords = ["session_meta", "turn_context", "thread_settings_applied", "user_message", "agent_message", "token_count", "compacted", "UserMessage", "AgentMessage"].map { Data($0.utf8) }
    static let turnEvents = ["task_started", "task_complete", "turn_aborted"]
    static let turnKeywords = turnEvents.map { Data($0.utf8) }

    public static func summary(of url: URL, name: String? = nil, pullRequests: [PullRequestLink]? = nil) -> SessionSummary? {
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

        let settings = tailRecords.lazy.reversed().compactMap(\.modelSettings).first ?? headRecords.lazy.reversed().compactMap(\.modelSettings).first
        let model = settings?.model
        let effort = settings?.effort
        let branch = meta.git?.branch.flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
        let lastTyped = tailRecords.last { $0.prompt != nil }?.timestamp.flatMap(date)
        let lastConversation = tailRecords.last { $0.isConversation }?.timestamp.flatMap(date)
        let tokens = tailRecords.lastIndex { $0.payload?.info?.lastInput != nil }
        let compaction = tailRecords.lastIndex { $0.type == "compacted" }
        let context: SessionContext? = if let tokens, let model, tokens > compaction ?? -1, let input = tailRecords[tokens].payload?.info?.lastInput {
            SessionContext(model: model, tokens: input, window: tailRecords[tokens].payload?.info?.window, modelName: model, effort: effort)
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
            pullRequests: pullRequests ?? Self.pullRequests(in: url, from: 0).links,
            context: context,
            modelSettings: settings,
            agent: .codex,
            startedAt: started
        )
    }

    static func pullRequests(in url: URL, from offset: Int) -> (links: [PullRequestLink], end: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url), (try? handle.seek(toOffset: UInt64(max(0, offset)))) != nil else { return ([], offset) }

        defer { try? handle.close() }
        let decoder = JSONDecoder()
        let limit = 4 * 1024 * 1024
        var links: [PullRequestLink] = []
        var seen = Set<PullRequestLink>()
        var end = max(0, offset)
        var dropping = false
        while let data = try? handle.read(upToCount: limit), !data.isEmpty {
            guard let newline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                if data.count < limit { break }
                dropping = true
                end += data.count
                continue
            }

            let consumed = newline + 1
            let complete = data.prefix(consumed)
            if complete.range(of: Data("/pull/".utf8)) != nil {
                for line in complete.split(separator: UInt8(ascii: "\n")).dropFirst(dropping ? 1 : 0) {
                    guard let record = try? decoder.decode(CodexTranscript.Record.self, from: Data(line)) else { continue }

                    let payload = record.payload
                    let output: String
                    if record.type == "response_item", payload.type == "function_call_output" || payload.type == "custom_tool_call_output" {
                        output = payload.output?.text ?? ""
                    } else if record.type == "event_msg", payload.type == "item_completed", payload.item?.type == "CommandExecution" {
                        output = payload.item?.aggregatedOutput ?? ""
                    } else {
                        continue
                    }
                    for text in output.components(separatedBy: "\n") {
                        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard text.range(of: #"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$"#, options: .regularExpression) != nil else { continue }

                        let parts = text.split(separator: "/")
                        guard let number = parts.last.flatMap({ Int($0) }) else { continue }

                        let link = PullRequestLink(repository: "\(parts[2])/\(parts[3])", number: number)
                        if seen.insert(link).inserted { links.append(link) }
                    }
                }
            }
            dropping = false
            end += consumed
            guard (try? handle.seek(toOffset: UInt64(end))) != nil else { break }
        }
        return (links, end)
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

    static func turnState(of url: URL) -> (isOpen: Bool, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (false, modified) }

        defer { try? handle.close() }
        let start = max(0, size - tailBytes)
        guard (try? handle.seek(toOffset: UInt64(max(0, start - 1)))) != nil,
              let data = try? handle.read(upToCount: tailBytes + 1)
        else { return (false, modified) }

        let dropFirst = start > 0 && data.first != UInt8(ascii: "\n")
        let latest = records(in: data, dropFirst: dropFirst, dropLast: false, keywords: turnKeywords).last { record in
            record.type == "event_msg" && turnEvents.contains(record.payload?.type ?? "")
        }
        return (latest.map { $0.payload?.type == "task_started" } ?? (start > 0), modified)
    }

    static func records(in data: Data, dropFirst: Bool, dropLast: Bool, keywords: [Data] = summaryKeywords) -> [Record] {
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

    struct Settings: Decodable {
        let model: String?
        let reasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case model
            case reasoningEffort = "reasoning_effort"
        }
    }

    struct CollaborationMode: Decodable {
        let settings: Settings?
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
            let effort: String?
            let threadSettings: Settings?
            let collaborationMode: CollaborationMode?
            let info: CodexRollout.Info?
            let item: CodexTranscript.Item?

            enum CodingKeys: String, CodingKey {
                case type, id, timestamp, cwd, originator, source, git, message, model, effort, info, item
                case threadSource = "thread_source", threadSettings = "thread_settings", collaborationMode = "collaboration_mode"
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
                effort = try? container.decode(String.self, forKey: .effort)
                threadSettings = try? container.decode(Settings.self, forKey: .threadSettings)
                collaborationMode = try? container.decode(CollaborationMode.self, forKey: .collaborationMode)
                info = try? container.decode(CodexRollout.Info.self, forKey: .info)
                item = try? container.decode(CodexTranscript.Item.self, forKey: .item)
            }
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?

        var modelSettings: SessionModelSettings? {
            if type == "event_msg", payload?.type == "thread_settings_applied", let settings = payload?.threadSettings, let model = settings.model {
                return SessionModelSettings(model: model, effort: settings.reasoningEffort)
            }
            guard type == "turn_context", let payload, let model = payload.model ?? payload.collaborationMode?.settings?.model else { return nil }

            return SessionModelSettings(model: model, effort: payload.effort ?? payload.collaborationMode?.settings?.reasoningEffort)
        }

        var prompt: String? {
            guard type == "event_msg" else { return nil }

            let message: String? = if payload?.type == "user_message" {
                payload?.message
            } else if payload?.type == "item_completed", payload?.item?.type == "UserMessage" {
                payload?.item?.content?.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
            } else {
                nil
            }
            guard let text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }

            return text
        }

        var isConversation: Bool {
            type == "event_msg" && (payload?.type == "user_message" || payload?.type == "agent_message" || payload?.type == "item_completed" && ["UserMessage", "AgentMessage"].contains(payload?.item?.type ?? ""))
        }
    }
}

public struct CodexIndex: SessionIndex {
    struct Entry: Sendable {
        let modified: Date
        let size: Int
        let name: String?
        let summary: SessionSummary?
        let pullRequests: [PullRequestLink]
        let scannedEnd: Int
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
            let cached = entries[file.path]
            let reset = size < (cached?.size ?? 0)
            let scanned = CodexRollout.pullRequests(in: file, from: reset ? 0 : cached?.scannedEnd ?? 0)
            let links = scanned.links.reduce(into: reset ? [] : cached?.pullRequests ?? []) { links, link in
                if !links.contains(link) { links.append(link) }
            }
            result[file.path] = Entry(modified: modified, size: size, name: name, summary: CodexRollout.summary(of: file, name: name, pullRequests: links) ?? cached?.summary, pullRequests: links, scannedEnd: scanned.end)
        }
        entries = next
        return next.values.compactMap(\.summary)
    }

    public func url(ofSession id: String) -> URL? {
        entries.first { $0.value.summary?.id == id }.map { URL(filePath: $0.key) }
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
