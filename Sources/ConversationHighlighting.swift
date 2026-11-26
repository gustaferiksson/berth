import AppKit
import SwiftUI

enum ConversationHighlighting {
    static let maxLines = 2000

    private static var cache: [String: [CodeHighlighter.Span]] = [:]

    static func attributed(_ text: String, language: String?, theme: GhosttyTheme) async -> AttributedString? {
        guard let colored = await colored(text, language: language, style: ReviewStyle.stored(ghostty: theme)) else { return nil }

        return try? AttributedString(colored, including: \.appKit)
    }

    static func highlighted(_ text: String, language: String?, theme: GhosttyTheme) async -> NSAttributedString? {
        let style = theme.code
        guard let spans = await spans(text, language: language) else { return nil }

        let colored = NSMutableAttributedString(string: text)
        for span in spans where NSMaxRange(span.range) <= colored.length {
            colored.addAttributes([.foregroundColor: style.color(forCapture: span.capture), .font: style.font(forCapture: span.capture)], range: span.range)
        }
        return colored
    }

    static func diffLines(_ rows: [(old: Bool, new: Bool, text: String)], language: String?, theme: GhosttyTheme) async -> [AttributedString] {
        let style = ReviewStyle.stored(ghostty: theme)
        var result = rows.map { AttributedString($0.text) }
        for side in [false, true] {
            let indices = rows.indices.filter { side ? rows[$0].new : rows[$0].old }
            guard let colored = await colored(indices.map { rows[$0].text }.joined(separator: "\n"), language: language, style: style) else { continue }

            var offset = 0
            for index in indices {
                let range = NSRange(location: offset, length: rows[index].text.utf16.count)
                offset = NSMaxRange(range) + 1
                guard side || !rows[index].new, let line = try? AttributedString(colored.attributedSubstring(from: range), including: \.appKit) else { continue }

                result[index] = line
            }
        }
        return result
    }

    private static func spans(_ text: String, language: String?) async -> [CodeHighlighter.Span]? {
        guard let language, text.utf8.count < 200_000, text.split(separator: "\n", omittingEmptySubsequences: false).count <= maxLines else { return nil }

        let key = "\(language)\n\(text.count)\n\(text.hashValue)"
        let spans: [CodeHighlighter.Span]
        if let cached = cache[key] {
            spans = cached
        } else {
            spans = await Task.detached(priority: .userInitiated) { CodeHighlighter.spans(in: text, language: language) }.value
            cache[key] = spans
        }
        return spans.isEmpty ? nil : spans
    }

    private static func colored(_ text: String, language: String?, style: ReviewStyle) async -> NSAttributedString? {
        guard let spans = await spans(text, language: language) else { return nil }

        let colored = NSMutableAttributedString(string: text)
        for span in spans where NSMaxRange(span.range) <= colored.length {
            colored.addAttribute(.foregroundColor, value: style.color(forCapture: span.capture), range: span.range)
        }
        return colored
    }
}

struct HighlightedConversationText: View {
    let text: String
    let language: String?

    @Environment(\.ghosttyTheme) private var theme
    @AppStorage(ReviewStyle.colorSchemeKey) private var colorScheme = ReviewColorScheme.terminal
    @AppStorage(ReviewStyle.syntaxColorsKey) private var syntaxColors = SyntaxColorSource.terminal
    @State private var attributed: AttributedString?

    var body: some View {
        Text(attributed ?? AttributedString(text))
            .task(id: [text, language ?? "", "\(theme.foreground)", colorScheme.rawValue, syntaxColors.rawValue]) { attributed = await ConversationHighlighting.attributed(text, language: language, theme: theme) }
    }
}
