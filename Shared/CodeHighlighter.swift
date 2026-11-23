import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

enum CodeHighlighter {
    struct Span: Equatable, Sendable {
        let range: NSRange
        let capture: String
    }

    private struct Grammar: Sendable {
        let language: Language
        let highlights: Query

        nonisolated init?(_ language: OpaquePointer, queries: [(bundle: String, file: String)], berthQueries: [String] = []) {
            let urls = queries.compactMap { query -> URL? in
                let name = (query.file as NSString).deletingPathExtension
                return Bundle.main.url(forResource: query.bundle, withExtension: "bundle").flatMap(Bundle.init(url:))?.url(forResource: name, withExtension: "scm", subdirectory: "queries")
            } + berthQueries.compactMap { Bundle.main.url(forResource: $0, withExtension: "scm") }
            let sources = urls.compactMap { try? Data(contentsOf: $0) }
            guard sources.count == queries.count + berthQueries.count, let highlights = try? Query(language: Language(language), data: Data(sources.joined(separator: Data("\n".utf8)))) else { return nil }

            self.language = Language(language)
            self.highlights = highlights
        }
    }

    private nonisolated static let javascriptQueries: [(bundle: String, file: String)] = [("TreeSitterJavaScript_TreeSitterJavaScript", "highlights.scm"), ("TreeSitterJavaScript_TreeSitterJavaScript", "highlights-jsx.scm")]
    private nonisolated static let swift = Grammar(tree_sitter_swift(), queries: [("TreeSitterSwift_TreeSitterSwift", "highlights.scm")])
    private nonisolated static let typescript = Grammar(tree_sitter_typescript(), queries: [("TreeSitterTypeScript_TreeSitterTypeScript", "highlights.scm"), javascriptQueries[0]], berthQueries: ["highlights-typescript"])
    private nonisolated static let tsx = Grammar(tree_sitter_tsx(), queries: [("TreeSitterTypeScript_TreeSitterTSX", "highlights.scm")] + javascriptQueries, berthQueries: ["highlights-typescript"])
    private nonisolated static let javascript = Grammar(tree_sitter_javascript(), queries: javascriptQueries)
    private nonisolated static let json = Grammar(tree_sitter_json(), queries: [("TreeSitterJSON_TreeSitterJSON", "highlights.scm")])
    private nonisolated static let markdown = Grammar(tree_sitter_markdown(), queries: [("TreeSitterMarkdown_TreeSitterMarkdown", "highlights.scm")])
    private nonisolated static let markdownInline = Grammar(tree_sitter_markdown_inline(), queries: [("TreeSitterMarkdown_TreeSitterMarkdownInline", "highlights.scm")])
    private nonisolated static let markdownInlineNodes = try? Query(language: Language(tree_sitter_markdown()), data: Data("(inline) @inline".utf8))
    private nonisolated static let yaml = Grammar(tree_sitter_yaml(), queries: [("TreeSitterYAML_TreeSitterYAML", "highlights.scm")])
    private nonisolated static let bash = Grammar(tree_sitter_bash(), queries: [("TreeSitterBash_TreeSitterBash", "highlights.scm")])
    private nonisolated static let css = Grammar(tree_sitter_css(), queries: [("TreeSitterCSS_TreeSitterCSS", "highlights.scm")])

    nonisolated static func spans(in text: String, language: String) -> [Span] {
        let spans = captures(in: text, language: language)
        let utf16 = Array(text.utf16)
        let brackets = spans.indices.filter { spans[$0].capture == "punctuation.bracket" && spans[$0].range.length == 1 && NSMaxRange(spans[$0].range) <= utf16.count }.sorted { spans[$0].range.location < spans[$1].range.location }
        let pairs: [UInt16: UInt16] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]
        var result = spans
        var open: [UInt16] = []
        for index in brackets {
            let unit = utf16[spans[index].range.location]
            if pairs.values.contains(unit) {
                result[index] = Span(range: spans[index].range, capture: "punctuation.bracket.\(open.count % 3)")
                open.append(unit)
            } else if let opener = pairs[unit], open.last == opener {
                open.removeLast()
                result[index] = Span(range: spans[index].range, capture: "punctuation.bracket.\(open.count % 3)")
            }
        }

        return result
    }

    private nonisolated static func captures(in text: String, language: String) -> [Span] {
        let pathExtension = language.contains(".") ? (language as NSString).pathExtension.lowercased() : language.lowercased()
        let parser = Parser()
        guard let grammar = grammar(forExtension: pathExtension), (try? parser.setLanguage(grammar.language)) != nil, let tree = parser.parse(text) else { return [] }

        let matches = grammar.highlights.execute(in: tree).resolve(with: .init(string: text))
        let groups = Dictionary(grouping: matches) { $0.metadata["priority"] == "declaration" }
        let highlights = groups[false, default: []].highlights() + groups[true, default: []].highlights()
        let spans = highlights.compactMap { $0.range.length > 0 && $0.name != "spell" ? Span(range: $0.range, capture: $0.name) : nil }
        guard ["md", "markdown"].contains(pathExtension), let markdownInline, let markdownInlineNodes else { return spans }

        let inlineRanges = markdownInlineNodes.execute(in: tree).flatMap { $0.captures.map(\.node.tsRange) }
        guard !inlineRanges.isEmpty, (try? parser.setLanguage(markdownInline.language)) != nil else { return spans }

        parser.includedRanges = inlineRanges
        guard let inlineTree = parser.parse(text) else { return spans }

        return spans + markdownInline.highlights.execute(in: inlineTree).resolve(with: .init(string: text)).highlights().compactMap { $0.range.length > 0 && $0.name != "spell" ? Span(range: $0.range, capture: $0.name) : nil }
    }

    private nonisolated static func grammar(forExtension pathExtension: String) -> Grammar? {
        if pathExtension == "swift" { return swift }
        if ["ts", "mts", "cts", "typescript"].contains(pathExtension) { return typescript }
        if pathExtension == "tsx" { return tsx }
        if ["js", "mjs", "cjs", "jsx", "javascript"].contains(pathExtension) { return javascript }
        if pathExtension == "json" { return json }
        if ["md", "markdown"].contains(pathExtension) { return markdown }
        if ["yml", "yaml"].contains(pathExtension) { return yaml }
        if pathExtension == "css" { return css }
        if ["bash", "zsh", "shell"].contains(pathExtension) { return bash }
        return nil
    }
}
