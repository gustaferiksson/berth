import AppKit
import SwiftUI

enum ConversationHighlighting {
    static let maxLines = 2000

    private static var cache: [String: [CodeHighlighter.Span]] = [:]

    static func attributed(_ text: String, language: String?, theme: GhosttyTheme) async -> AttributedString? {
        guard let colored = await colored(text, language: language, style: style(theme)) else { return nil }

        return try? AttributedString(colored, including: \.appKit)
    }

    static func diffLines(_ rows: [(old: Bool, new: Bool, text: String)], language: String?, theme: GhosttyTheme) async -> [AttributedString] {
        let style = style(theme)
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

    private static func style(_ theme: GhosttyTheme) -> ReviewStyle {
        ReviewStyle(scheme: .terminal, fontFamily: "", fontSize: 0, lineHeightMultiple: 1, ghostty: theme)
            .withSyntaxColors(SyntaxColorSource(rawValue: UserDefaults.standard.string(forKey: ReviewStyle.syntaxColorsKey) ?? "") ?? .terminal)
    }

    private static func colored(_ text: String, language: String?, style: ReviewStyle) async -> NSAttributedString? {
        guard let language, text.utf8.count < 200_000, text.split(separator: "\n", omittingEmptySubsequences: false).count <= maxLines else { return nil }

        let key = "\(language)\n\(text.count)\n\(text.hashValue)"
        let spans: [CodeHighlighter.Span]
        if let cached = cache[key] {
            spans = cached
        } else {
            spans = await Task.detached(priority: .userInitiated) { CodeHighlighter.spans(in: text, language: language) }.value
            cache[key] = spans
        }
        guard !spans.isEmpty else { return nil }

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
    @State private var attributed: AttributedString?

    var body: some View {
        Text(attributed ?? AttributedString(text))
            .task(id: [text, language ?? "", "\(theme.foreground)"]) { attributed = await ConversationHighlighting.attributed(text, language: language, theme: theme) }
    }
}
