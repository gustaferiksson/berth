import Foundation

public indirect enum MarkdownNode: Equatable, Sendable {
    case heading(Int, AttributedString)
    case paragraph(AttributedString)
    case images([MarkdownImage])
    case code(language: String, text: String)
    case quote([Self])
    case list(start: Int?, items: [MarkdownItem])
    case table([[AttributedString]])
    case rule
}

public struct MarkdownImage: Equatable, Sendable {
    public let source: String
    public let alt: String
}

public struct MarkdownItem: Equatable, Sendable {
    public let checked: Bool?
    public let content: [MarkdownNode]
}

public enum MarkdownDocument {
    private struct Leaf {
        var chain: [PresentationIntent.IntentType]
        var text: AttributedString

        func identity(at depth: Int) -> Int? { chain.indices.contains(depth) ? chain[depth].identity : nil }
    }

    public static func isMarkdown(path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    public static func nodes(in source: String) -> [MarkdownNode] {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        var leaves: [Leaf] = []
        for run in parsed.runs where run.inlinePresentationIntent?.contains(.inlineHTML) != true {
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            let chain = Array((run.presentationIntent?.components ?? []).reversed())
            if let last = leaves.last, !chain.isEmpty, last.chain.map(\.identity) == chain.map(\.identity) {
                leaves[leaves.count - 1].text += piece
            } else {
                leaves.append(Leaf(chain: chain, text: piece))
            }
        }
        return nodes(in: groups(of: leaves[...], depth: 0), depth: 0)
    }

    private static func groups(of leaves: ArraySlice<Leaf>, depth: Int) -> [ArraySlice<Leaf>] {
        var result: [ArraySlice<Leaf>] = []
        var start = leaves.startIndex
        while start < leaves.endIndex {
            var end = start + 1
            if let identity = leaves[start].identity(at: depth) {
                while end < leaves.endIndex, leaves[end].identity(at: depth) == identity { end += 1 }
            }
            result.append(leaves[start..<end])
            start = end
        }
        return result
    }

    private static func nodes(in groups: [ArraySlice<Leaf>], depth: Int) -> [MarkdownNode] {
        groups.map { node($0, depth: depth) }
    }

    private static func node(_ group: ArraySlice<Leaf>, depth: Int) -> MarkdownNode {
        let text = group.reduce(into: AttributedString()) { $0 += $1.text }
        guard let first = group.first, first.chain.indices.contains(depth) else { return .paragraph(text) }

        let kind = first.chain[depth].kind
        if case let .header(level) = kind { return .heading(level, text) }
        if case let .codeBlock(language) = kind { return .code(language: language ?? "", text: text.characters.last == "\n" ? String(String(text.characters).dropLast()) : String(text.characters)) }
        if case .thematicBreak = kind { return .rule }
        if case .blockQuote = kind { return .quote(nodes(in: groups(of: group, depth: depth + 1), depth: depth + 1)) }
        if case .orderedList = kind { return list(group, depth: depth, isOrdered: true) }
        if case .unorderedList = kind { return list(group, depth: depth, isOrdered: false) }
        if case let .table(columns) = kind { return table(group, depth: depth, columnCount: columns.count) }
        if case .paragraph = kind { return images(in: text).map(MarkdownNode.images) ?? .paragraph(text) }
        return .paragraph(text)
    }

    private static func images(in text: AttributedString) -> [MarkdownImage]? {
        let images = text.runs.compactMap { run in run.imageURL.map { MarkdownImage(source: $0.absoluteString, alt: String(text[run.range].characters)) } }
        let isOnlyImages = text.runs.allSatisfy { $0.imageURL != nil || text[$0.range].characters.allSatisfy(\.isWhitespace) }
        return isOnlyImages && !images.isEmpty ? images : nil
    }

    private static func list(_ group: ArraySlice<Leaf>, depth: Int, isOrdered: Bool) -> MarkdownNode {
        let itemGroups = groups(of: group, depth: depth + 1)
        var start: Int?
        if isOrdered, case let .listItem(ordinal)? = itemGroups.first?.first?.chain[depth + 1].kind { start = ordinal }
        let items = itemGroups.map { item -> MarkdownItem in
            var content = nodes(in: groups(of: item, depth: depth + 2), depth: depth + 2)
            guard case let .paragraph(text)? = content.first else { return MarkdownItem(checked: nil, content: content) }

            let marker = String(text.characters.prefix(4))
            guard ["[ ] ", "[x] ", "[X] "].contains(marker) else { return MarkdownItem(checked: nil, content: content) }

            var rest = text
            rest.removeSubrange(rest.startIndex..<rest.index(rest.startIndex, offsetByCharacters: 4))
            content[0] = .paragraph(rest)
            return MarkdownItem(checked: marker != "[ ] ", content: content)
        }
        return .list(start: start, items: items)
    }

    private static func table(_ group: ArraySlice<Leaf>, depth: Int, columnCount: Int) -> MarkdownNode {
        let rows = groups(of: group, depth: depth + 1).map { row in
            var cells = Array(repeating: AttributedString(), count: columnCount)
            for cell in groups(of: row, depth: depth + 2) {
                guard case let .tableCell(index)? = cell.first?.chain[depth + 2].kind, cells.indices.contains(index) else { continue }

                cells[index] = cell.reduce(into: AttributedString()) { $0 += $1.text }
            }
            return cells
        }
        return .table(rows)
    }
}
