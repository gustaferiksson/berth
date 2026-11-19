import Foundation
import SwiftTreeSitter
import TreeSitterCSS
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

enum ReviewHighlighter {
    struct Span: Equatable, Sendable {
        let range: NSRange
        let capture: String
    }

    private struct Grammar: Sendable {
        let language: Language
        let highlights: Query

        nonisolated init?(_ language: OpaquePointer, queries: [(bundle: String, file: String)]) {
            guard let resources = Bundle.main.resourceURL else { return nil }

            let sources = queries.compactMap { try? Data(contentsOf: resources.appending(path: "\($0.bundle).bundle/Contents/Resources/queries/\($0.file)")) }
            guard sources.count == queries.count, let highlights = try? Query(language: Language(language), data: Data(sources.joined(separator: Data("\n".utf8)))) else { return nil }

            self.language = Language(language)
            self.highlights = highlights
        }
    }

    private nonisolated static let javascriptQueries: [(bundle: String, file: String)] = [("TreeSitterJavaScript_TreeSitterJavaScript", "highlights.scm"), ("TreeSitterJavaScript_TreeSitterJavaScript", "highlights-jsx.scm")]
    private nonisolated static let swift = Grammar(tree_sitter_swift(), queries: [("TreeSitterSwift_TreeSitterSwift", "highlights.scm")])
    private nonisolated static let typescript = Grammar(tree_sitter_typescript(), queries: [("TreeSitterTypeScript_TreeSitterTypeScript", "highlights.scm"), javascriptQueries[0]])
    private nonisolated static let tsx = Grammar(tree_sitter_tsx(), queries: [("TreeSitterTypeScript_TreeSitterTSX", "highlights.scm")] + javascriptQueries)
    private nonisolated static let javascript = Grammar(tree_sitter_javascript(), queries: javascriptQueries)
    private nonisolated static let json = Grammar(tree_sitter_json(), queries: [("TreeSitterJSON_TreeSitterJSON", "highlights.scm")])
    private nonisolated static let markdown = Grammar(tree_sitter_markdown(), queries: [("TreeSitterMarkdown_TreeSitterMarkdown", "highlights.scm")])
    private nonisolated static let markdownInline = Grammar(tree_sitter_markdown_inline(), queries: [("TreeSitterMarkdown_TreeSitterMarkdownInline", "highlights.scm")])
    private nonisolated static let markdownInlineNodes = try? Query(language: Language(tree_sitter_markdown()), data: Data("(inline) @inline".utf8))
    private nonisolated static let yaml = Grammar(tree_sitter_yaml(), queries: [("TreeSitterYAML_TreeSitterYAML", "highlights.scm")])
    private nonisolated static let css = Grammar(tree_sitter_css(), queries: [("TreeSitterCSS_TreeSitterCSS", "highlights.scm")])

    nonisolated static func spans(in text: String, path: String) -> [Span] {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        let parser = Parser()
        guard let grammar = grammar(forExtension: pathExtension), (try? parser.setLanguage(grammar.language)) != nil, let tree = parser.parse(text) else { return [] }

        let spans = grammar.highlights.execute(in: tree).resolve(with: .init(string: text)).highlights().compactMap { $0.range.length > 0 && $0.name != "spell" ? Span(range: $0.range, capture: $0.name) : nil }
        guard pathExtension == "md", let markdownInline, let markdownInlineNodes else { return spans }

        let inlineRanges = markdownInlineNodes.execute(in: tree).flatMap { $0.captures.map(\.node.tsRange) }
        guard !inlineRanges.isEmpty, (try? parser.setLanguage(markdownInline.language)) != nil else { return spans }

        parser.includedRanges = inlineRanges
        guard let inlineTree = parser.parse(text) else { return spans }

        return spans + markdownInline.highlights.execute(in: inlineTree).resolve(with: .init(string: text)).highlights().compactMap { $0.range.length > 0 && $0.name != "spell" ? Span(range: $0.range, capture: $0.name) : nil }
    }

    private nonisolated static func grammar(forExtension pathExtension: String) -> Grammar? {
        if pathExtension == "swift" { return swift }
        if ["ts", "mts", "cts"].contains(pathExtension) { return typescript }
        if pathExtension == "tsx" { return tsx }
        if ["js", "mjs", "cjs", "jsx"].contains(pathExtension) { return javascript }
        if pathExtension == "json" { return json }
        if pathExtension == "md" { return markdown }
        if ["yml", "yaml"].contains(pathExtension) { return yaml }
        if pathExtension == "css" { return css }
        return nil
    }
}
