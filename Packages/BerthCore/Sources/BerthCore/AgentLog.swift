import Foundation

public struct AgentLog: Sendable {
    static let chunkBytes = 4 << 20
    static let recentCalls = 20
    static let replyCharacters = 4000
    static let summaryKeys = ["description", "command", "file_path", "pattern", "query", "url", "path", "prompt"]
    static let assistantMarker = Data(#""type":"assistant""#.utf8)

    public private(set) var end = 0
    public private(set) var toolCount = 0
    public private(set) var tokens: Int?
    public private(set) var calls: [RemoteToolCall] = []
    public private(set) var reply: String?
    private var seen: Set<String> = []

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

    @discardableResult
    mutating func apply(_ data: Data) -> Int {
        var consumed = data.startIndex
        while let newline = data[consumed...].firstIndex(of: 0x0A) {
            note(data[consumed..<newline])
            consumed = newline + 1
        }
        return consumed - data.startIndex
    }

    private mutating func note(_ line: Data) {
        guard line.range(of: Self.assistantMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any]
        else { return }

        let date = (object["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let fresh = blocks.compactMap { block -> RemoteToolCall? in
            guard block["type"] as? String == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String, seen.insert(id).inserted else { return nil }

            let input = block["input"] as? [String: Any] ?? [:]
            let summary = Self.summaryKeys.lazy.compactMap { input[$0] as? String }.first ?? ""
            return RemoteToolCall(name: name, summary: String(summary.split(whereSeparator: \.isNewline).first ?? "").prefix(200).description, date: date)
        }
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { reply = String(text.prefix(Self.replyCharacters)) }
        toolCount += fresh.count
        calls = Array((calls + fresh).suffix(Self.recentCalls))
        if let usage = message["usage"] as? [String: Any] {
            let total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
            if total > 0 { tokens = total }
        }
    }
}
