import Foundation

public struct MarkdownFrontmatter: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let key: String
        public let value: String
        public let isNested: Bool
    }

    public enum Content: Equatable, Sendable {
        case entries([Entry])
        case raw(String)
    }

    public let content: Content
    public let body: String

    public static func split(_ source: String) -> Self? {
        let lines = source.replacing("\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let first = lines.first, fence(first.replacing("\u{FEFF}", with: "")) == "---",
              let close = lines.indices.dropFirst().first(where: { ["---", "..."].contains(fence(lines[$0])) }) else { return nil }

        let block = lines[1..<close]
        return Self(
            content: entries(in: block).map(Content.entries) ?? .raw(block.joined(separator: "\n")),
            body: lines[(close + 1)...].joined(separator: "\n")
        )
    }

    private static func fence(_ line: String) -> String {
        line.replacing(/\s+$/, with: "")
    }

    private static func entries(in block: ArraySlice<String>) -> [Entry]? {
        var result: [(key: String, lines: [String], isNested: Bool)] = []
        for line in block {
            let isContinuation = line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("- ") || line == "-"
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let last = result.last, last.isNested { result[result.count - 1].lines.append("") }
                continue
            }
            if isContinuation {
                guard !result.isEmpty else { return nil }

                result[result.count - 1].lines.append(line)
                result[result.count - 1].isNested = true
                continue
            }
            if line.hasPrefix("#") { continue }

            guard let separator = line.firstMatch(of: /:(\s|$)/) else { return nil }

            let key = String(line[..<separator.range.lowerBound])
            let value = line[separator.range.upperBound...].trimmingCharacters(in: .whitespaces)
            let isFlow = ["|", ">", "[", "{"].contains { value.hasPrefix($0) }
            result.append((key, value.isEmpty ? [] : [isFlow ? value : unquoted(value)], isFlow))
        }
        return result.map { entry in
            let lines = Array(entry.lines.reversed().drop(while: \.isEmpty).reversed())
            return Entry(key: entry.key, value: lines.joined(separator: "\n"), isNested: entry.isNested)
        }
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return value }

        return String(value.dropFirst().dropLast())
    }
}
