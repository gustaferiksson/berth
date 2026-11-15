import Foundation

public enum TranscriptTail {
    public struct Chunk: Sendable {
        public let entries: [RemoteEntry]
        public let end: Int
        public let isContinuation: Bool
    }

    static let tailBytes = 256 * 1024
    static let maxTailBytes = 8 * 1024 * 1024
    static let maxText = 4000
    static let minEntries = 50

    public static func read(_ url: URL, after offset: Int?) -> Chunk? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = (try? handle.seekToEnd()).map(Int.init) else { return nil }
        defer { try? handle.close() }

        if let offset, offset <= size, size - offset <= tailBytes {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
            let parsed = entries(in: (try? handle.readToEnd()) ?? Data(), dropFirst: false)
            return Chunk(entries: parsed.entries, end: offset + parsed.consumed, isContinuation: true)
        }

        var window = tailBytes
        while true {
            let start = max(0, size - window)
            guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return nil }
            let parsed = entries(in: (try? handle.readToEnd()) ?? Data(), dropFirst: start > 0)
            if start == 0 || window >= maxTailBytes || parsed.entries.count >= minEntries {
                return Chunk(entries: parsed.entries, end: start + parsed.consumed, isContinuation: false)
            }
            window *= 2
        }
    }

    static func entries(in data: Data, dropFirst: Bool) -> (entries: [RemoteEntry], consumed: Int) {
        let consumed = data.lastIndex(of: UInt8(ascii: "\n")).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        let lines = data.prefix(consumed).split(separator: UInt8(ascii: "\n")).dropFirst(dropFirst ? 1 : 0)
        let decoder = JSONDecoder()
        let entries = lines.flatMap { line -> [RemoteEntry] in
            guard !line.starts(with: Data(#"{"type":"api-request"#.utf8)),
                  line.range(of: Data(#""type":"user""#.utf8)) != nil || line.range(of: Data(#""type":"assistant""#.utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
                  let uuid = object["uuid"] as? String,
                  let message = object["message"] as? [String: Any]
            else { return [] }

            if type == "user", let prompt = (try? decoder.decode(Record.self, from: Data(line)))?.typedPrompt {
                return [RemoteEntry(id: uuid, kind: .prompt, text: prompt)]
            }

            let blocks = message["content"] as? [[String: Any]] ?? []
            return blocks.enumerated().compactMap { index, block in
                let id = "\(uuid)-\(index)"
                if type == "assistant", block["type"] as? String == "text", let text = block["text"] as? String {
                    return RemoteEntry(id: id, kind: .reply, text: text)
                }
                if type == "assistant", block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    let input = block["input"] as? [String: Any] ?? [:]
                    let raw = String(decoding: (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
                    return RemoteEntry(
                        id: id,
                        kind: .toolUse,
                        text: String(raw.prefix(maxText)),
                        toolID: block["id"] as? String,
                        name: name,
                        command: (input["command"] as? String).map { String($0.prefix(maxText)) },
                        filePath: input["file_path"] as? String,
                        oldText: (input["old_string"] as? String).map { String($0.prefix(maxText)) },
                        newText: (input["new_string"] as? String ?? input["content"] as? String).map { String($0.prefix(maxText)) }
                    )
                }
                guard type == "user", block["type"] as? String == "tool_result" else { return nil }
                let content = block["content"] as? String ?? (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                return RemoteEntry(id: id, kind: .toolResult, text: String(content.prefix(maxText)), toolID: block["tool_use_id"] as? String, isError: block["is_error"] as? Bool ?? false)
            }
        }
        return (entries, consumed)
    }
}
