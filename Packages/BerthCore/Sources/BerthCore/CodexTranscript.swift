import Foundation

public enum CodexTranscript {
    struct Content: Decodable {
        let type: String?
        let text: String?
        let title: String?
        let url: String?
    }

    enum Output: Decodable {
        case text(String)
        case blocks([Content])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            self = try .blocks(container.decode([Content].self))
        }

        var text: String {
            switch self {
            case let .text(text): text
            case let .blocks(blocks): blocks.filter { $0.type == "input_text" }.compactMap(\.text).joined(separator: "\n")
            }
        }
    }

    struct Arguments: Decodable {
        struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil

            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue _: Int) { nil }
        }

        let strings: [String: String]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            strings = container.allKeys.reduce(into: [:]) { values, key in
                values[key.stringValue] = try? container.decode(String.self, forKey: key)
            }
        }
    }

    struct Change: Decodable {
        let type: String
        let content: String?
        let unifiedDiff: String?
        let movePath: String?

        enum CodingKeys: String, CodingKey {
            case type, content
            case unifiedDiff = "unified_diff", movePath = "move_path"
        }
    }

    struct Item: Decodable {
        let type: String
        let id: String?
        let content: [Content]?
        let command: [String]?
        let aggregatedOutput: String?
        let exitCode: Int?
        let status: String?
        let changes: [String: Change]?
        let stdout: String?
        let stderr: String?

        enum CodingKeys: String, CodingKey {
            case type, id, content, command, status, changes, stdout, stderr
            case aggregatedOutput = "aggregated_output", exitCode = "exit_code"
        }
    }

    struct Payload: Decodable {
        let type: String?
        let id: String?
        let callID: String?
        let message: String?
        let reason: String?
        let name: String?
        let arguments: String?
        let input: String?
        let output: Output?
        let item: Item?
        let changes: [String: Change]?
        let success: Bool?
        let stdout: String?
        let stderr: String?
        let query: String?
        let results: [Content]?

        enum CodingKeys: String, CodingKey {
            case type, id, message, reason, name, arguments, input, output, item, changes, success, stdout, stderr, query, results
            case callID = "call_id"
        }
    }

    struct Record: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
    }

    public static func read(_ url: URL, after offset: Int?, queue: [String]) -> TranscriptTail.Chunk? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }

        let head = (try? handle.read(upToCount: CodexRollout.headBytes)) ?? Data()
        try? handle.close()
        let itemsEra = head.range(of: Data("item_completed".utf8)) != nil
        return TranscriptTail.readWindow(url, after: offset) { data, dropFirst, start, continuation in
            let consumed = data.lastIndex(of: UInt8(ascii: "\n")).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
            let lines = data.prefix(consumed).split(separator: UInt8(ascii: "\n")).dropFirst(dropFirst ? 1 : 0)
            let parsed = entries(in: lines.map { Data($0) }, itemsEra: itemsEra)
            return TranscriptTail.Chunk(entries: parsed.entries, end: start + consumed, isContinuation: continuation, queue: queue, imageLines: [:], isTurnOpen: parsed.isTurnOpen)
        }
    }

    static func entries(in lines: [Data], itemsEra: Bool) -> (entries: [RemoteEntry], isTurnOpen: Bool?) {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let execNames: Set = ["exec_command", "shell", "shell_command", "container.exec"]
        let skippedNames: Set = ["wait", "write_stdin", "sleep", "send_message", "wait_agent", "list_agents", "followup_task"]
        var entries: [RemoteEntry] = []
        var seenPrompts = Set<String>()
        var seenReplies = Set<String>()
        var isTurnOpen: Bool?
        var skippedCall: String?
        for line in lines {
            let previousSkippedCall = skippedCall
            skippedCall = nil
            guard let record = try? decoder.decode(Record.self, from: line) else { continue }

            let payload = record.payload
            let type = payload.type ?? ""
            let item = payload.item
            let date = CodexRollout.date(record.timestamp)
            let callID = payload.callID ?? item?.id ?? payload.id
            let id = callID ?? "\(record.timestamp)-0"
            if record.type == "event_msg" {
                if type == "task_started" { isTurnOpen = true }
                if type == "task_complete" || type == "turn_aborted" { isTurnOpen = false }
                let kind: RemoteEntry.Kind? = switch type {
                case "user_message": .prompt
                case "agent_message": .reply
                case "turn_aborted" where payload.reason == "interrupted": .prompt
                case "item_completed" where item?.type == "UserMessage": .prompt
                case "item_completed" where item?.type == "AgentMessage": .reply
                default: nil
                }
                if let kind {
                    let text = type == "turn_aborted" ? "[Request interrupted by user]" : type == "item_completed" ? (item?.content ?? []).filter { kind == .reply || $0.type == "text" }.compactMap(\.text).joined(separator: "\n") : payload.message ?? ""
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                    if kind == .prompt {
                        guard !seenPrompts.contains(text) else { continue }

                        seenPrompts = [text]
                        seenReplies.removeAll()
                    } else {
                        guard seenReplies.insert(text).inserted else { continue }
                    }
                    entries.append(RemoteEntry(id: id, kind: kind, text: String(text.prefix(TranscriptTail.maxText)), date: date))
                    continue
                }
            }
            if record.type == "event_msg", type == "patch_apply_end" || type == "item_completed" && itemsEra && item?.type == "FileChange" {
                let changes = type == "patch_apply_end" ? payload.changes : item?.changes
                let success = type == "patch_apply_end" ? payload.success == true : item?.status == "completed"
                let stdout = type == "patch_apply_end" ? payload.stdout : item?.stdout
                let stderr = type == "patch_apply_end" ? payload.stderr : item?.stderr
                for (index, path) in (changes ?? [:]).keys.sorted().enumerated() {
                    guard let change = changes?[path] else { continue }

                    var old: [String] = []
                    var new: [String] = []
                    for line in (change.unifiedDiff ?? "").components(separatedBy: "\n") {
                        if line.hasPrefix("@@") || line.hasPrefix("\\ No newline") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") { continue }
                        if line.hasPrefix(" ") && change.type != "delete" || line.hasPrefix("-") { old.append(String(line.dropFirst())) }
                        if line.hasPrefix(" ") || line.hasPrefix("+") { new.append(String(line.dropFirst())) }
                    }
                    let toolID = "\(callID ?? record.timestamp)-\(index)"
                    entries.append(RemoteEntry(id: callID == nil ? "\(record.timestamp)-\(index * 2)" : toolID, kind: .toolUse, text: "", toolID: toolID, name: change.type == "add" ? "Write" : "Edit", filePath: String(path.prefix(TranscriptTail.maxText)), oldText: change.type == "add" ? nil : String(old.joined(separator: "\n").prefix(TranscriptTail.maxText)), newText: String((change.type == "add" ? change.content ?? "" : change.type == "delete" ? "" : new.joined(separator: "\n")).prefix(TranscriptTail.maxText)), date: date, detail: change.movePath.map { String("moved to \($0)".prefix(TranscriptTail.maxDetail)) }))
                    entries.append(RemoteEntry(id: callID == nil ? "\(record.timestamp)-\(index * 2 + 1)" : "\(toolID)-result", kind: .toolResult, text: String((success ? stdout ?? "" : stderr.flatMap { $0.isEmpty ? nil : $0 } ?? "Failed").prefix(TranscriptTail.maxText)), toolID: toolID, isError: !success, date: date))
                }
                continue
            }
            if record.type == "event_msg", type == "item_completed", itemsEra, item?.type == "CommandExecution", let item {
                let command = item.command ?? []
                let text = command.count > 2 && ["-lc", "-c"].contains(command[1]) ? command[2] : command.joined(separator: " ")
                let raw = String(decoding: (try? encoder.encode(["command": text])) ?? Data(), as: UTF8.self)
                entries.append(RemoteEntry(id: id, kind: .toolUse, text: String(raw.prefix(TranscriptTail.maxText)), toolID: callID, name: "Bash", command: String(text.prefix(TranscriptTail.maxText)), date: date))
                entries.append(RemoteEntry(id: callID.map { "\($0)-result" } ?? "\(record.timestamp)-1", kind: .toolResult, text: String((item.aggregatedOutput ?? "").prefix(TranscriptTail.maxText)), toolID: callID, isError: item.exitCode.map { $0 != 0 } == true || item.status == "failed", date: date))
                continue
            }
            if record.type == "event_msg", type == "web_search_end" {
                let raw = String(decoding: (try? encoder.encode(["query": payload.query ?? ""])) ?? Data(), as: UTF8.self)
                entries.append(RemoteEntry(id: id, kind: .toolUse, text: String(raw.prefix(TranscriptTail.maxText)), toolID: callID, name: "WebSearch", date: date, detail: payload.query.map { String($0.prefix(TranscriptTail.maxDetail)) }))
                let text = (payload.results ?? []).prefix(8).map { "\($0.title ?? "") \($0.url ?? "")" }.joined(separator: "\n")
                entries.append(RemoteEntry(id: callID.map { "\($0)-result" } ?? "\(record.timestamp)-1", kind: .toolResult, text: String(text.prefix(TranscriptTail.maxText)), toolID: callID, date: date))
                continue
            }
            guard record.type == "response_item" else { continue }

            if type == "function_call" || type == "custom_tool_call" {
                let name = payload.name ?? ""
                if skippedNames.contains(name) || itemsEra && (execNames.contains(name) || type == "custom_tool_call" && name == "exec") {
                    skippedCall = callID
                    continue
                }
                let arguments = payload.arguments ?? ""
                let values = (try? decoder.decode(Arguments.self, from: Data(arguments.utf8)).strings) ?? [:]
                if execNames.contains(name) {
                    let text = values["cmd"] ?? values["command"] ?? ""
                    let raw = String(decoding: (try? encoder.encode(["command": text])) ?? Data(), as: UTF8.self)
                    entries.append(RemoteEntry(id: id, kind: .toolUse, text: String(raw.prefix(TranscriptTail.maxText)), toolID: callID, name: "Bash", command: String(text.prefix(TranscriptTail.maxText)), date: date))
                    continue
                }
                if type == "custom_tool_call", name == "exec" {
                    let input = payload.input ?? ""
                    let pattern = #"\bcmd\s*:\s*("(?:\\.|[^"\\])*")"#
                    let regex = try? NSRegularExpression(pattern: pattern)
                    let commands = (regex?.matches(in: input, range: NSRange(input.startIndex..., in: input)) ?? []).compactMap { match -> String? in
                        guard let range = Range(match.range(at: 1), in: input) else { return nil }

                        return try? decoder.decode(String.self, from: Data(input[range].utf8))
                    }
                    let command = commands.isEmpty ? nil : commands.joined(separator: "\n")
                    let detail = input.contains("apply_patch") ? "apply_patch" : String((input.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "").prefix(120))
                    let raw = command.map { String(decoding: (try? encoder.encode(["command": $0])) ?? Data(), as: UTF8.self) } ?? input
                    entries.append(RemoteEntry(id: id, kind: .toolUse, text: String(raw.prefix(TranscriptTail.maxText)), toolID: callID, name: command == nil ? "Script" : "Bash", command: command.map { String($0.prefix(TranscriptTail.maxText)) }, date: date, detail: command == nil ? detail : nil))
                    continue
                }
                let detail = ["message", "prompt", "task", "query", "url", "path", "cmd"].compactMap { values[$0] }.first
                entries.append(RemoteEntry(id: id, kind: .toolUse, text: String(arguments.prefix(TranscriptTail.maxText)), toolID: callID, name: name == "update_plan" ? "TodoWrite" : name, date: date, detail: name == "update_plan" ? nil : detail.map { String($0.prefix(TranscriptTail.maxDetail)) }))
                continue
            }
            guard type == "function_call_output" || type == "custom_tool_call_output", previousSkippedCall == nil || previousSkippedCall != callID else { continue }

            var output = payload.output?.text ?? ""
            let isError = output.range(of: #"Process exited with code (?!0\b)-?\d+"#, options: .regularExpression) != nil
            if type == "custom_tool_call_output", case let .blocks(blocks)? = payload.output {
                let texts = blocks.filter { $0.type == "input_text" }.compactMap(\.text)
                output = texts.dropFirst(texts.first.map { $0.hasPrefix("Script completed") || $0.hasPrefix("Script running") } == true ? 1 : 0).joined(separator: "\n")
            } else if output.hasPrefix("Chunk ID:") || output.hasPrefix("Wall time:") || output.hasPrefix("Process exited with code "), let range = output.range(of: "Output:\n") {
                output = String(output[range.upperBound...])
            }
            entries.append(RemoteEntry(id: id, kind: .toolResult, text: String(output.prefix(TranscriptTail.maxText)), toolID: callID, isError: isError, date: date))
        }
        return (entries, isTurnOpen)
    }
}
