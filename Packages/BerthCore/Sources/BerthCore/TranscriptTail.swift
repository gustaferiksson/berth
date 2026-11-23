import Foundation

public enum TranscriptTail {
    public struct Chunk: Sendable {
        public let entries: [RemoteEntry]
        public let end: Int
        public let isContinuation: Bool
        public let queue: [String]
        public let imageLines: [String: Range<Int>]
        public var isTurnOpen: Bool?

        public var queuedPrompts: [String] {
            queue.filter { !$0.isEmpty && !$0.hasPrefix("<") }
        }
    }

    static let tailBytes = 256 * 1024
    static let maxTailBytes = 32 * 1024 * 1024
    static let maxText = 4000
    static let minEntries = 50
    static let minPrompts = 5
    static let maxDetail = 300
    static let maxImages = 4
    static let thumbnailPixels = 1000
    static let maxThumbnailBytes = 300 * 1024

    public static func read(_ url: URL, after offset: Int?, queue: [String] = [], includeSidechain: Bool = false) -> Chunk? {
        readWindow(url, after: offset) { data, dropFirst, start, continuation in
            let parsed = entries(in: data, dropFirst: dropFirst, queue: continuation ? queue : [], baseOffset: start, includeSidechain: includeSidechain)
            return Chunk(entries: parsed.entries, end: start + parsed.consumed, isContinuation: continuation, queue: parsed.queue, imageLines: parsed.imageLines)
        }
    }

    static func readWindow(_ url: URL, after offset: Int?, parse: (Data, Bool, Int, Bool) -> Chunk) -> Chunk? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = (try? handle.seekToEnd()).map(Int.init) else { return nil }

        defer { try? handle.close() }
        if let offset, offset >= 0, offset <= size, size - offset <= maxTailBytes {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }

            return parse((try? handle.readToEnd()) ?? Data(), false, offset, true)
        }
        var window = tailBytes
        while true {
            let start = max(0, size - window)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return nil }

            let chunk = parse((try? handle.readToEnd()) ?? Data(), start > 0, start, false)
            if start == 0 || window >= maxTailBytes || chunk.entries.count >= minEntries && chunk.entries.count(where: { $0.kind == .prompt }) >= minPrompts { return chunk }

            window *= 2
        }
    }

    // Claude Code saves mid-turn updates as thinking blocks whose signature decodes to bytes containing "narration" (real thinking says "thinking")
    static func isNarration(signature: String?) -> Bool {
        guard let signature else { return false }

        let prefix = signature.prefix(256)
        let padded = prefix + String(repeating: "=", count: (4 - prefix.count % 4) % 4)

        return Data(base64Encoded: String(padded)).map { $0.range(of: Data("narration".utf8)) != nil } ?? false
    }

    static func entries(in data: Data, dropFirst: Bool, queue: [String], baseOffset: Int = 0, includeSidechain: Bool = false) -> (entries: [RemoteEntry], consumed: Int, queue: [String], imageLines: [String: Range<Int>]) {
        let consumed = data.lastIndex(of: UInt8(ascii: "\n")).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        let lines = data.prefix(consumed).split(separator: UInt8(ascii: "\n")).dropFirst(dropFirst ? 1 : 0)
        let decoder = JSONDecoder()
        let entriesOf = { (rawLine: Data) -> [RemoteEntry] in
            let line = TranscriptImages.redactingImageData(rawLine)
            guard !line.starts(with: Data(#"{"type":"api-request"#.utf8)),
                  line.range(of: Data(#""type":"user""#.utf8)) != nil || line.range(of: Data(#""type":"assistant""#.utf8)) != nil || line.range(of: Data(#""type":"queued_command""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  includeSidechain || object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let uuid = (object["uuid"] as? String).map({ String($0.prefix(maxText)) })
            else { return [] }

            let date = (object["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }

            if type == "attachment" {
                guard (try? decoder.decode(Record.self, from: Data(line)))?.isQueuedPrompt == true, let attachment = object["attachment"] as? [String: Any] else { return [] }

                let blocks = attachment["prompt"] as? [[String: Any]] ?? [["type": "text", "text": attachment["prompt"] as? String ?? ""]]
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n").prefix(maxText)
                return [prompt(id: uuid, text: String(text), date: date, blocks: blocks)]
            }

            guard type == "user" || type == "assistant", let message = object["message"] as? [String: Any] else { return [] }

            let blocks = message["content"] as? [[String: Any]] ?? []

            if type == "user", let record = try? decoder.decode(Record.self, from: Data(line)) {
                let raw = record.message?.content.first(where: { $0.type == "text" })?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let input = raw.wholeMatch(of: /(?s)<bash-input>(.*)<\/bash-input>/) {
                    let command = String(input.1.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxText))
                    return [RemoteEntry(id: uuid, kind: .prompt, text: command, name: "bash", command: command, date: date)]
                }
                if let output = raw.wholeMatch(of: /(?s)(?:<bash-stdout>(?<stdout>.*?)<\/bash-stdout>\s*)?(?:<bash-stderr>(?<stderr>.*)<\/bash-stderr>)?/),
                   output.stdout != nil || output.stderr != nil {
                    let stdout = output.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let stderr = output.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return [RemoteEntry(id: uuid, kind: .toolResult, text: String(stdout.prefix(maxText)), name: "bash-output", date: date, detail: stderr.isEmpty ? nil : String(stderr.prefix(maxDetail)))]
                }
                if let text = record.typedPrompt(includingSidechain: includeSidechain) {
                    return [prompt(id: uuid, text: String(text.prefix(maxText)), date: date, blocks: blocks)]
                }
            }

            return blocks.enumerated().compactMap { index, block in
                let id = "\(uuid)-\(index)"
                if type == "assistant", let blockType = block["type"] as? String, blockType == "text" || blockType == "thinking",
                   blockType == "text" || isNarration(signature: block["signature"] as? String),
                   let text = block[blockType] as? String, !text.isEmpty {
                    return RemoteEntry(id: id, kind: .reply, text: String(text.prefix(maxText)), date: date)
                }
                if type == "assistant", block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let raw = String(decoding: (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
                    let question = ((input["questions"] as? [[String: Any]])?.first)?["question"] as? String
                    return RemoteEntry(
                        id: id,
                        kind: .toolUse,
                        text: String(raw.prefix(maxText)),
                        toolID: (block["id"] as? String).map { String($0.prefix(maxText)) },
                        name: String(name.prefix(maxText)),
                        command: (input["command"] as? String).map { String($0.prefix(maxText)) },
                        filePath: (input["file_path"] as? String ?? input["notebook_path"] as? String).map { String($0.prefix(maxText)) },
                        oldText: (input["old_string"] as? String).map { String($0.prefix(maxText)) },
                        newText: (input["new_string"] as? String ?? input["content"] as? String).map { String($0.prefix(maxText)) },
                        date: date,
                        detail: (question ?? ["description", "pattern", "query", "url", "skill", "message"].lazy.compactMap { input[$0] as? String }.first).map { String($0.prefix(maxDetail)) }
                    )
                }
                guard type == "user", block["type"] as? String == "tool_result" else { return nil }

                let blockContent = block["content"] as? String ?? (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                let isVirtualResult = (block["tool_use_id"] as? String)?.hasPrefix("repl_") == true
                let content = blockContent.isEmpty && isVirtualResult ? virtualResultText(object["toolUseResult"] as? [String: Any] ?? [:]) : blockContent
                let refs = TranscriptImages.refs(in: block, entryID: id)
                return RemoteEntry(id: id, kind: .toolResult, text: String(content.prefix(maxText)), toolID: (block["tool_use_id"] as? String).map { String($0.prefix(maxText)) }, isError: block["is_error"] as? Bool ?? false, date: date, imageRefs: refs.isEmpty ? nil : refs)
            }
        }
        let parsed = lines.map { line in
            let start = baseOffset + line.startIndex - data.startIndex
            return (entries: entriesOf(line), range: start..<start + line.count)
        }
        let entries = parsed.flatMap(\.entries)
        let readImages = Set(entries.lazy.filter { $0.kind == .toolUse && $0.name == "Read" && TranscriptImages.isImagePath($0.filePath) }.compactMap(\.toolID))
        let resolved = entries.map { entry in
            guard entry.kind == .toolResult, !entry.isError, entry.imageRefs == nil, let toolID = entry.toolID, readImages.contains(toolID) else { return entry }

            var entry = entry
            entry.imageRefs = [RemoteImageRef(id: "\(entry.id)-file", bytes: 0)]
            return entry
        }
        let operations = lines.lazy
            .filter { $0.range(of: Data(#""type":"queue-operation""#.utf8)) != nil }
            .compactMap { try? decoder.decode(Record.self, from: Data($0)) }
        let queue = operations.reduce(into: queue) { queue, record in
            if record.operation == "enqueue" {
                queue.append(record.content ?? "")
            } else if record.operation == "dequeue", !queue.isEmpty {
                queue.removeFirst()
            } else if record.operation == "remove", let index = queue.firstIndex(of: record.content ?? "") {
                queue.remove(at: index)
            } else if record.operation == "popAll" {
                queue.removeAll()
            }
        }
        let rangeByEntry = Dictionary(parsed.flatMap { line in line.entries.map { ($0.id, line.range) } }) { $1 }
        let imageLines = Dictionary(resolved.flatMap { entry in (entry.imageRefs ?? []).compactMap { ref in rangeByEntry[entry.id].map { (ref.id, $0) } } }) { $1 }
        return (resolved, consumed, queue, imageLines)
    }

    // Code Mode's virtual tool_result records carry an empty content; the inner tool's output is in toolUseResult
    static func virtualResultText(_ result: [String: Any]) -> String {
        if let task = result["backgroundTaskId"] as? String { return "Command running in background with ID: \(task)" }

        if result["isAsync"] as? Bool == true, let agent = result["agentId"] as? String { return "Async agent launched successfully.\nagentId: \(agent)" }

        let output = [result["stdout"] as? String, result["stderr"] as? String].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
        if !output.isEmpty { return output }

        if let content = (result["file"] as? [String: Any])?["content"] as? String { return content }

        let blocks = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        return blocks.isEmpty ? result["message"] as? String ?? "" : blocks
    }

    static func prompt(id: String, text: String, date: Date?, blocks: [[String: Any]]) -> RemoteEntry {
        let images = Array(blocks.lazy.compactMap { block -> Data? in
            guard block["type"] as? String == "image",
                  let base64 = (block["source"] as? [String: Any])?["data"] as? String,
                  let data = Data(base64Encoded: base64),
                  let thumbnail = TranscriptImages.jpeg(data, maxPixel: thumbnailPixels, quality: 0.85),
                  thumbnail.count <= maxThumbnailBytes
            else { return nil }

            return thumbnail
        }.prefix(maxImages))
        let shown = images.isEmpty ? text : text.replacing(/\[Image #\d+\]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteEntry(id: id, kind: .prompt, text: shown, date: date, images: images.isEmpty ? nil : images)
    }
}
