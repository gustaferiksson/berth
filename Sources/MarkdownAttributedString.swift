import AppKit
import BerthCore
import SwiftUI

extension NSAttributedString.Key {
    static let markdownCodeBlock = NSAttributedString.Key("berth.markdownCodeBlock")
    static let markdownTable = NSAttributedString.Key("berth.markdownTable")
}

enum MarkdownAttributedString {
    static let blockPadding = 12.0
    static let codeLabelHeight = 16.0

    static let codeLineLimit = 12

    struct Unit {
        var content: NSAttributedString
        var terminator: [NSAttributedString.Key: Any]
    }

    static func codeBlocks(in blocks: [MarkdownBlock]) -> [(language: String, code: String)] {
        blocks.compactMap { block in
            guard case let .code(language) = block.kind else { return nil }

            return (language, block.lines.joined(separator: "\n"))
        }
    }

    static func highlightKey(language: String, code: String) -> String { "\(language)\n\(code)" }

    static func render(_ blocks: [MarkdownBlock], theme: GhosttyTheme, highlighted: [String: NSAttributedString] = [:], proseFont: NSFont? = nil, itemID: String? = nil, expanded: Set<String> = []) -> NSAttributedString {
        let font = proseFont ?? theme.conversationNSFont()
        let gap: [NSAttributedString.Key: Any] = [.font: font.withSize(4)]
        var units: [Unit] = []
        var codeIndex = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                let isItemRun = if case .item = block.kind, case .item = blocks[index - 1].kind { true } else { false }
                if !isItemRun { units.append(Unit(content: NSAttributedString(), terminator: gap)) }
            }
            switch block.kind {
            case let .code(language):
                let code = block.lines.joined(separator: "\n")
                let key = itemID.map { "\($0)#code\(codeIndex)" }
                units += codeUnits(code, language: language, theme: theme, highlighted: highlighted[highlightKey(language: language, code: code)], key: key, expanded: expanded)
                codeIndex += 1

            case .table:
                units += tableUnits(block.lines, theme: theme)

            default:
                units.append(proseUnit(block, font: font, theme: theme))
            }
        }

        return assemble(units)
    }

    static func assemble(_ units: [Unit]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, unit) in units.enumerated() {
            result.append(unit.content)
            if index < units.count - 1 { result.append(NSAttributedString(string: "\n", attributes: unit.terminator)) }
        }
        return result
    }

    static func inline(_ source: String, font: NSFont, theme: GhosttyTheme, traits: NSFontDescriptor.SymbolicTraits = []) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runTraits = traits
            if intent.contains(.stronglyEmphasized) { runTraits.insert(.bold) }
            if intent.contains(.emphasized) { runTraits.insert(.italic) }

            let runFont = intent.contains(.code) ? theme.conversationCodeNSFont().withSize(font.pointSize) : font
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(descriptor: runFont.fontDescriptor.withSymbolicTraits(runFont.fontDescriptor.symbolicTraits.union(runTraits)), size: font.pointSize) ?? runFont,
                .foregroundColor: NSColor(theme.foreground),
            ]
            if intent.contains(.code) { attributes[.foregroundColor] = NSColor(theme.inlineCode) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor(theme.unread)
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static func proseUnit(_ block: MarkdownBlock, font base: NSFont, theme: GhosttyTheme) -> Unit {
        let source = block.lines.joined(separator: "\n")
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.lineHeightMultiple
        var content: NSMutableAttributedString
        var terminator: [NSAttributedString.Key: Any] = [.font: base]
        switch block.kind {
        case let .heading(level):
            let increase: CGFloat = level == 1 ? 4 : level == 2 ? 2 : 1
            content = inline(source, font: base.withSize(base.pointSize + increase), theme: theme, traits: .bold)

        case let .item(marker, depth):
            let prefix = NSMutableAttributedString(string: String(repeating: " ", count: depth * 2) + marker + " ", attributes: [.font: base, .foregroundColor: NSColor(theme.secondary)])
            style.headIndent = prefix.size().width
            content = prefix
            content.append(inline(source, font: base, theme: theme))

        default:
            content = inline(source, font: base, theme: theme)
        }
        content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
        terminator[.paragraphStyle] = style
        return Unit(content: content, terminator: terminator)
    }

    static func expansionLink(_ title: String, key: String, copyText: String, attributes: [NSAttributedString.Key: Any], theme: GhosttyTheme) -> NSAttributedString {
        var components = URLComponents()
        components.scheme = "berth-expand"
        components.host = "toggle"
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        var attributes = attributes
        attributes[.link] = components.url
        attributes[.foregroundColor] = NSColor(theme.secondary)
        attributes[.conversationCopyText] = copyText
        return NSAttributedString(string: title, attributes: attributes)
    }

    static func codeUnits(_ code: String, language: String, theme: GhosttyTheme, highlighted: NSAttributedString? = nil, key: String? = nil, expanded: Set<String> = []) -> [Unit] {
        let font = theme.conversationCodeNSFont(-1)
        let whole = NSMutableAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor(theme.foreground)])
        highlighted?.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: min(highlighted?.length ?? 0, whole.length))) { color, range, _ in
            if let color { whole.addAttribute(.foregroundColor, value: color, range: range) }
        }

        let nsCode = code as NSString
        var lineRanges: [NSRange] = []
        nsCode.enumerateSubstrings(in: NSRange(location: 0, length: nsCode.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in lineRanges.append(range) }
        if lineRanges.isEmpty || code.last?.isNewline == true { lineRanges.append(NSRange(location: nsCode.length, length: 0)) }

        let toggleKey = lineRanges.count > codeLineLimit ? key : nil
        let isCollapsed = toggleKey.map { !expanded.contains($0) } ?? false
        let visible = isCollapsed ? codeLineLimit : lineRanges.count
        let top = blockPadding + (language.isEmpty ? 0 : codeLabelHeight) + 1
        return (0..<(visible + (toggleKey == nil ? 0 : 1))).map { index in
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = blockPadding
            style.headIndent = blockPadding
            style.tailIndent = -blockPadding
            if index == 0 { style.paragraphSpacingBefore = top }
            if index == visible || index == visible - 1 && toggleKey == nil { style.paragraphSpacing = blockPadding + 1 }

            let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .markdownCodeBlock: language]
            if index == visible, let toggleKey {
                let hidden = isCollapsed ? lineRanges.dropFirst(visible).map { nsCode.substring(with: $0) }.joined(separator: "\n") : ""
                let title = isCollapsed ? "Show \(lineRanges.count - visible) more lines" : "Show less"
                let link = expansionLink(title, key: toggleKey, copyText: isCollapsed ? "\n" + hidden : "", attributes: attributes, theme: theme)
                return Unit(content: link, terminator: attributes)
            }

            let content = NSMutableAttributedString(attributedString: whole.attributedSubstring(from: lineRanges[index]))
            let range = NSRange(location: 0, length: content.length)
            content.addAttributes(attributes, range: range)
            if isCollapsed, index >= visible - 3 {
                let alpha = [0.70, 0.45, 0.25][index - (visible - 3)]
                content.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                    if let color = value as? NSColor { content.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * alpha), range: run) }
                }
            }
            var terminator = attributes
            if index == visible - 1, toggleKey != nil { terminator[.conversationCopyText] = "" }
            return Unit(content: content, terminator: terminator)
        }
    }

    private static func tableUnits(_ lines: [String], theme: GhosttyTheme) -> [Unit] {
        let rows = lines
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { row in !row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
        let base = theme.conversationNSFont(0)
        let cells = rows.enumerated().map { index, row in row.map { inline($0, font: base, theme: theme, traits: index == 0 ? .bold : []) } }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in cells.map { column < $0.count ? $0[column].size().width : 0 }.max() ?? 0 }
        let gutter = 20.0
        let stops = widths.indices.dropFirst().map { column in
            NSTextTab(textAlignment: .left, location: blockPadding + widths[..<column].reduce(0, +) + gutter * Double(column), options: [:])
        }
        return cells.enumerated().map { index, row in
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = blockPadding
            style.headIndent = blockPadding
            style.tailIndent = -blockPadding
            style.tabStops = stops
            style.defaultTabInterval = 0
            if index == 0 { style.paragraphSpacingBefore = blockPadding + 1 }
            style.paragraphSpacing = index == cells.count - 1 ? blockPadding + 1 : 6

            let content = NSMutableAttributedString()
            for (column, cell) in row.enumerated() {
                if column > 0 { content.append(NSAttributedString(string: "\t", attributes: [.font: base])) }
                content.append(cell)
            }
            let attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style, .markdownTable: true]
            content.addAttributes(attributes, range: NSRange(location: 0, length: content.length))
            return Unit(content: content, terminator: attributes.merging([.font: base]) { $1 })
        }
    }
}
