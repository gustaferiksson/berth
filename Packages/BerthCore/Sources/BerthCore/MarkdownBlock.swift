import Foundation

public struct MarkdownBlock: Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph, table
        case heading(Int)
        case item(String, depth: Int)
        case code(String)
    }

    public let kind: Kind
    public var lines: [String]

    public static func linkedInline(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
    }

    public static func inline(_ source: String) -> AttributedString {
        linkedInline(source).transformingAttributes(\.link) { $0.value = nil }
    }

    public static func compact(_ text: String) -> AttributedString {
        let lines = blocks(in: text.replacing(/!\[[^\]]*\]\([^)]*\)/, with: "")).flatMap { block -> [String] in
            if case let .item(marker, depth) = block.kind { return [String(repeating: "  ", count: depth) + marker + " " + block.lines.joined(separator: " ")] }
            if block.kind == .paragraph { return [block.lines.joined(separator: " ")] }
            return block.lines
        }
        return inline(lines.joined(separator: "\n"))
    }

    public static func blocks(in text: String) -> [Self] {
        var blocks: [Self] = []
        var isInFence = false
        var continues = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInFence.toggle()
                if isInFence { blocks.append(Self(kind: .code(String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)), lines: [])) }
                continues = false
                continue
            }
            if isInFence {
                blocks[blocks.count - 1].lines.append(line)
                continue
            }

            if trimmed.isEmpty {
                continues = false
            } else if let heading = trimmed.prefixMatch(of: /(#{1,6})\s+/) {
                blocks.append(Self(kind: .heading(heading.output.1.count), lines: [String(trimmed[heading.range.upperBound...])]))
                continues = false
            } else if let item = line.prefixMatch(of: /(\s*)([-*+]|\d+[.)])\s+/) {
                let marker = String(item.output.2)
                blocks.append(Self(kind: .item(marker.first?.isNumber == true ? marker : "•", depth: item.output.1.count / 2), lines: [String(line[item.range.upperBound...])]))
                continues = true
            } else if trimmed.hasPrefix("|") {
                if blocks.last?.kind == .table { blocks[blocks.count - 1].lines.append(trimmed) } else { blocks.append(Self(kind: .table, lines: [trimmed])) }
                continues = false
            } else if continues {
                blocks[blocks.count - 1].lines.append(trimmed)
            } else {
                blocks.append(Self(kind: .paragraph, lines: [line]))
                continues = true
            }
        }
        return blocks
    }
}
