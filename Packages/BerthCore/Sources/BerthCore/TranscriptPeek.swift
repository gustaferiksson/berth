import Foundation

public struct PeekMessage: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case prompt
        case reply
        case tools
    }

    public let kind: Kind
    public let text: String
}

extension Transcript {
    static let peekBytes = 256 * 1024
    static let maxPeekBytes = 4 * 1024 * 1024
    static let maxPromptLength = 300
    static let maxReplyLength = 600

    public static func recentMessages(of url: URL, exchanges: Int = 3) -> [PeekMessage] {
        recentMessages(of: url, exchanges: exchanges, window: peekBytes)
    }

    static func recentMessages(of url: URL, exchanges: Int, window: Int) -> [PeekMessage] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let tail = try? handle.readToEnd() else { return [] }
        let messages = recentMessages(in: records(in: tail, dropFirst: offset > 0, dropLast: false), exchanges: exchanges)
        guard offset > 0, window < maxPeekBytes, messages.filter({ $0.kind == .prompt }).count < exchanges else { return messages }
        return recentMessages(of: url, exchanges: exchanges, window: maxPeekBytes)
    }

    static func recentMessages(in records: [Record], exchanges limit: Int) -> [PeekMessage] {
        let entries = records.flatMap { record -> [PeekMessage] in
            if let prompt = record.typedPrompt {
                return [PeekMessage(kind: .prompt, text: prompt)]
            }
            guard record.type == "assistant", record.isSidechain != true else { return [] }
            return (record.message?.content ?? []).compactMap { block in
                if block.type == "tool_use" { return block.name.map { PeekMessage(kind: .tools, text: $0) } }
                guard block.type == "text", let text = block.text, !text.allSatisfy(\.isWhitespace) else { return nil }
                return PeekMessage(kind: .reply, text: text)
            }
        }
        let exchanges = entries.reduce(into: [[PeekMessage]]()) { result, entry in
            if entry.kind == .prompt || result.isEmpty {
                result.append([entry])
            } else {
                result[result.count - 1].append(entry)
            }
        }
        let prompted = exchanges.filter { $0.first?.kind == .prompt }
        return (prompted.isEmpty ? exchanges.suffix(1) : prompted.suffix(limit)).flatMap { exchange in
            let tools = exchange.filter { $0.kind == .tools }.map(\.text)
            let reply = exchange.last { $0.kind == .reply }
            return exchange.prefix { $0.kind == .prompt }.map { PeekMessage(kind: .prompt, text: plain($0.text, limit: maxPromptLength)) }
                + (tools.isEmpty ? [] : [PeekMessage(kind: .tools, text: toolSummary(tools))])
                + (reply.map { [PeekMessage(kind: .reply, text: plain($0.text, limit: maxReplyLength))] } ?? [])
        }
    }

    static func plain(_ text: String, limit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { $0.replacing(/^#{1,6}\s+/, with: "") }
        let joined = lines.joined(separator: "\n").replacing(/\n{3,}/, with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > limit else { return joined }
        return joined.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func toolSummary(_ names: [String]) -> String {
        let kinds: [(names: Set<String>, verb: String, one: String, many: String)] = [
            (["Bash"], "ran", "shell command", "shell commands"),
            (["Read"], "read", "file", "files"),
            (["Edit", "MultiEdit", "Write", "NotebookEdit"], "edited", "file", "files"),
            (["Grep", "Glob"], "searched", "time", "times"),
            (["Agent", "Task"], "started", "agent", "agents"),
        ]
        let known = kinds.reduce(into: Set<String>()) { $0.formUnion($1.names) }
        let other = names.filter { !known.contains($0) }.count
        let parts = kinds.compactMap { kind -> String? in
            let count = names.filter(kind.names.contains).count
            return count == 0 ? nil : "\(kind.verb) \(count) \(count == 1 ? kind.one : kind.many)"
        } + (other == 0 ? [] : ["used \(other) \(other == 1 ? "tool" : "tools")"])
        let sentence = parts.joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}
