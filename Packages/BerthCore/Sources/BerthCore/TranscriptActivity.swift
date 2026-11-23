import Foundation

public struct TranscriptActivity: Sendable {
    struct Launch: Sendable {
        let tool: String
        let title: String
        let started: Date
        var deadline: Date?
        var command: String?
        var agentType: String?
        var output: String?
    }

    struct Reply: Sendable {
        let model: String
        var tokens: Int?
        let date: Date
    }

    static let tools = ["Agent", "Task", "Bash", "Monitor", "SendMessage", "TaskStop"]
    static let agentTools: Set<String> = ["Agent", "Task"]
    static let toolNames = tools.map { Array(#""name":"\#($0)""#.utf8) }
    static let resultKey = Array(#""tool_use_id":""#.utf8)
    static let virtualLaunchKeys = [#""agentId":""#, #""resumedAgentId":""#, #""backgroundTaskId":""#, #""taskId":""#].map { Array($0.utf8) }
    static let chunkBytes = 4 << 20
    static let requestPrefix = Array(#"{"type":"api-request","#.utf8)
    static let mainThreadSources = [#""querySource":"repl_main_thread"#, #""querySource":"main_thread"#].map { Array($0.utf8) }
    static let requestEffort = Array(#""output_config":{"effort":""#.utf8)
    static let permissionModePrefix = Array(#"{"type":"permission-mode","#.utf8)
    static let permissionModeKey = Array(#""permissionMode":""#.utf8)

    public private(set) var end = 0
    var pending: [String: Launch] = [:]
    var running: [String: Launch] = [:]
    var ended: [String: Date] = [:]
    var agentTitles: [String: String] = [:]
    var agentTypes: [String: String] = [:]
    var reply: Reply?
    var compactions = 0
    var lastCompaction: Date?
    var effort: String?
    public private(set) var permissionMode: String?

    public init() {}

    public mutating func read(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return }

        defer { try? handle.close() }
        if Int(size) < end { self = Self() }
        guard (try? handle.seek(toOffset: UInt64(end))) != nil else { return }

        var buffer = Data()
        while let chunk = try? handle.read(upToCount: Self.chunkBytes), !chunk.isEmpty {
            buffer.append(chunk)
            let consumed = apply(buffer)
            end += consumed
            buffer = Data(buffer.dropFirst(consumed))
        }
    }

    public func tasks(of live: LiveSession?, now: Date, progress: [String: AgentLog] = [:], isFinished: (String) -> Bool) -> [RemoteTask] {
        guard let live, let status = live.status, let startedAt = live.startedAt.map({ Date(timeIntervalSince1970: $0 / 1000) }) else { return [] }

        let background = running.filter { id, launch in
            launch.started >= startedAt
                && launch.deadline.map { now < $0 } ?? true
                && !(launch.tool == "Bash" && status == "idle")
                && !(Self.agentTools.contains(launch.tool) && isFinished(id))
        }
        let foreground = ["busy", "waiting"].contains(status) ? pending.filter { Self.agentTools.contains($0.value.tool) && $0.value.started >= startedAt } : [:]
        return background.merging(foreground) { first, _ in first }
            .map { id, launch in
                RemoteTask(id: id, kind: Self.agentTools.contains(launch.tool) ? RemoteTask.agent : launch.tool == "Bash" ? RemoteTask.shell : RemoteTask.monitor, title: launch.title, started: launch.started, command: launch.command, agentType: launch.agentType, toolCount: progress[id]?.toolCount, tokens: progress[id]?.tokens, call: progress[id]?.calls.last)
            }
            .sorted { ($0.started, $0.id) < ($1.started, $1.id) }
    }

    public var runningAgentIDs: [String] {
        running.filter { Self.agentTools.contains($0.value.tool) }.map(\.key)
    }

    public func outputFile(of task: String) -> URL? {
        guard let path = running[task]?.output else { return nil }

        let url = URL(filePath: path)
        return url.lastPathComponent == "\(task).output" ? url : nil
    }

    public var model: String? {
        reply?.model
    }

    public func context(window: Int?) -> RemoteContext? {
        guard let reply else { return nil }

        let fits = window.map { reply.tokens ?? 0 <= $0 } ?? false
        return RemoteContext(model: reply.model, tokens: reply.tokens, window: fits ? window : nil, date: reply.date, compactions: compactions, lastCompaction: lastCompaction, effort: effort)
    }

    public static func catalogModel(_ model: String, catalogs: [Data]) -> (window: Int?, name: String?) {
        let entries = catalogs
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .sorted { $0["fetchedAt"] as? Double ?? 0 > $1["fetchedAt"] as? Double ?? 0 }
            .lazy
            .flatMap { (($0["catalog"] as? [String: Any])?["config"] as? [String: Any])?["models"] as? [[String: Any]] ?? [] }
            .filter { $0["id"] as? String == model }
        return (entries.compactMap { ($0["runtime"] as? [String: Any])?["max_input_tokens"] as? Int }.first, entries.compactMap { $0["name"] as? String }.first)
    }

    @discardableResult
    mutating func apply(_ data: Data) -> Int {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return 0 }

            var replies: [Data] = []
            var start = 0
            while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
                let line = UnsafeRawBufferPointer(rebasing: buffer[start..<base.distance(to: newline)])
                start = base.distance(to: newline) + 1
                let find = { (pattern: [UInt8]) in memmem(line.baseAddress, line.count, pattern, pattern.count) }
                if line.starts(with: Self.permissionModePrefix) {
                    if let found = find(Self.permissionModeKey) {
                        let value = UnsafeRawBufferPointer(rebasing: line[(line.baseAddress!.distance(to: found) + Self.permissionModeKey.count)...])
                        permissionMode = String(decoding: value.prefix { $0 != UInt8(ascii: "\"") }, as: UTF8.self)
                    }
                    continue
                }
                if line.starts(with: Self.requestPrefix) {
                    if Self.mainThreadSources.contains(where: { find($0) != nil }), let found = find(Self.requestEffort) {
                        effort = Self.level(at: UnsafeRawBufferPointer(rebasing: line[(line.baseAddress!.distance(to: found) + Self.requestEffort.count)...]))
                    }
                    continue
                }
                if let found = find(SessionPicker.effortConfirmation) {
                    effort = Self.level(at: UnsafeRawBufferPointer(rebasing: line[(line.baseAddress!.distance(to: found) + SessionPicker.effortConfirmation.count)...])) ?? effort
                    continue
                }
                let resultID = find(Self.resultKey).map { found in
                    String(decoding: UnsafeRawBufferPointer(rebasing: line[(line.baseAddress!.distance(to: found) + Self.resultKey.count)...]).prefix { $0 != UInt8(ascii: "\"") }, as: UTF8.self)
                }
                let isReply = find(Array(#""type":"assistant""#.utf8)) != nil && find(Array(#""isSidechain":true"#.utf8)) == nil && find(Array(#""model":"<synthetic>""#.utf8)) == nil
                if isReply { replies.append(Data(line)) }
                guard isReply && find(Array(#""type":"tool_use""#.utf8)) != nil && Self.toolNames.contains(where: { find($0) != nil })
                    || find(Array(#""compact_boundary""#.utf8)) != nil
                    || find(Array("<task-notification>".utf8)) != nil
                    || resultID.map({ pending[$0] != nil }) ?? false
                    || resultID?.hasPrefix("repl_") == true && Self.virtualLaunchKeys.contains(where: { find($0) != nil }),
                    let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    object["isSidechain"] as? Bool != true,
                    let date = (object["timestamp"] as? String).flatMap({ try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) })
                else { continue }

                if object["type"] as? String == "system", object["subtype"] as? String == "compact_boundary" {
                    note(replies)
                    replies = []
                    compactions += 1
                    lastCompaction = date
                    reply?.tokens = nil
                }
                launch(object, at: date)
                resolve(object, at: date)
                endNotified(object, at: date)
            }
            note(replies)
            return start
        }
    }

    static func level(at text: UnsafeRawBufferPointer) -> String? {
        let word = String(decoding: text.prefix { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") }, as: UTF8.self)
        return EffortLevel(rawValue: word) == nil ? nil : word
    }

    mutating func note(_ replies: [Data]) {
        for line in replies.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any],
                  let date = (object["timestamp"] as? String).flatMap({ try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) })
            else { continue }

            let tokens = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
            guard tokens > 0 else { continue }

            reply = Reply(model: model, tokens: tokens, date: date)
            return
        }
    }

    mutating func launch(_ object: [String: Any], at date: Date) {
        guard object["type"] as? String == "assistant", let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }

        for block in blocks where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let tool = block["name"] as? String, Self.tools.contains(tool) else { continue }

            let input = block["input"] as? [String: Any] ?? [:]
            let title = ["description", "summary", "command"].lazy.compactMap { input[$0] as? String }.first ?? tool
            pending[id] = Launch(tool: tool, title: title, started: date, command: input["command"] as? String, agentType: input["subagent_type"] as? String)
        }
    }

    mutating func resolve(_ object: [String: Any], at date: Date) {
        guard object["type"] as? String == "user", let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return }

        let result = object["toolUseResult"] as? [String: Any] ?? [:]
        for block in blocks where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String,
                  let launch = pending.removeValue(forKey: id) ?? Self.replLaunch(id: id, result: result, at: date),
                  block["is_error"] as? Bool != true
            else { continue }

            if launch.tool == "TaskStop", let task = result["task_id"] as? String {
                end(task, at: date)
            } else if Self.agentTools.contains(launch.tool), result["isAsync"] as? Bool == true, let agent = result["agentId"] as? String {
                agentTitles[agent] = launch.title
                agentTypes[agent] = launch.agentType
                start(agent, launch)
            } else if launch.tool == "SendMessage", let agent = result["resumedAgentId"] as? String {
                start(agent, Launch(tool: "Agent", title: agentTitles[agent] ?? launch.title, started: launch.started, agentType: agentTypes[agent]))
            } else if launch.tool == "Bash", let task = result["backgroundTaskId"] as? String {
                let content = block["content"] as? String ?? (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                var started = launch
                started.output = content.firstMatch(of: /written to:? (\/[^\s;]+?)\.?(?:\s|;|$)/)?.1.description
                start(task, started)
            } else if launch.tool == "Monitor", let task = result["taskId"] as? String {
                let timeout = result["persistent"] as? Bool == true ? nil : result["timeoutMs"] as? Double
                start(task, Launch(tool: launch.tool, title: launch.title, started: launch.started, deadline: timeout.map { launch.started + $0 / 1000 }, command: launch.command))
            }
        }
    }

    static func replLaunch(id: String, result: [String: Any], at date: Date) -> Launch? {
        guard id.hasPrefix("repl_") else { return nil }

        let title = result["description"] as? String
        if result["isAsync"] as? Bool == true, result["agentId"] != nil {
            return Launch(tool: "Agent", title: title ?? "Agent", started: date, agentType: result["subagent_type"] as? String)
        }
        if result["resumedAgentId"] != nil {
            return Launch(tool: "SendMessage", title: "Agent", started: date)
        }
        if result["backgroundTaskId"] != nil {
            return Launch(tool: "Bash", title: title ?? "Background shell", started: date)
        }
        if result["taskId"] != nil {
            return Launch(tool: "Monitor", title: title ?? "Monitor", started: date)
        }
        return nil
    }

    mutating func endNotified(_ object: [String: Any], at date: Date) {
        let type = object["type"] as? String
        let attachment = object["attachment"] as? [String: Any]
        let carried: Any? = if type == "queue-operation", object["operation"] as? String == "enqueue" {
            object["content"]
        } else if type == "user", (object["origin"] as? [String: Any])?["kind"] as? String == "task-notification" {
            (object["message"] as? [String: Any])?["content"]
        } else if type == "attachment", attachment?["type"] as? String == "queued_command" {
            attachment?["prompt"]
        } else {
            nil
        }
        let text = carried as? String ?? (carried as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")

        for notification in text.components(separatedBy: "<task-notification>").dropFirst() {
            guard notification.contains("<status>") || notification.contains(/<event>\s*\[Monitor (expired|timed out)/) else { continue }

            for match in notification.matches(of: /<task-id>([^<]*)<\/task-id>/) { end(String(match.1), at: date) }
        }
    }

    mutating func start(_ id: String, _ launch: Launch) {
        let reusesID = Self.agentTools.contains(launch.tool)
        guard ended[id].map({ reusesID && $0 < launch.started }) ?? true else { return }

        running[id] = launch
    }

    mutating func end(_ id: String, at date: Date) {
        ended[id] = max(ended[id] ?? .distantPast, date)
        guard let launch = running[id], launch.started <= date else { return }

        running[id] = nil
    }
}
