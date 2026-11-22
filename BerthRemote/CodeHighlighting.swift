import SwiftUI

enum CodeHighlighting {
    nonisolated static let maxLines = 2000

    private final nonisolated class Cache: @unchecked Sendable {
        private let storage = NSCache<NSString, NSArray>()

        func text(forKey key: String) -> NSAttributedString?? {
            storage.object(forKey: key as NSString).map { $0.firstObject as? NSAttributedString }
        }

        func set(_ text: NSAttributedString?, forKey key: String) {
            storage.setObject(text.map { [$0] } ?? [], forKey: key as NSString)
        }
    }

    private nonisolated static let cache = Cache()

    nonisolated static func attributed(_ text: String, language: String?) async -> AttributedString? {
        await Task.detached(priority: .userInitiated) {
            colored(text, language: language).flatMap { try? AttributedString($0, including: \.uiKit) }
        }.value
    }

    nonisolated static func diffLines(_ rows: [(old: Bool, new: Bool, text: String)], language: String?) async -> [AttributedString] {
        await Task.detached(priority: .userInitiated) {
            var result = rows.map { AttributedString($0.text) }
            var start = 0
            for end in rows.indices + [rows.count] where end == rows.count || (!rows[end].old && !rows[end].new) {
                let segment = Array(start..<end)
                start = end + 1
                for (index, line) in lines(of: rows, at: segment.filter { rows[$0].old }, language: language) where !rows[index].new {
                    result[index] = line
                }
                for (index, line) in lines(of: rows, at: segment.filter { rows[$0].new }, language: language) {
                    result[index] = line
                }
            }
            return result
        }.value
    }

    private nonisolated static func lines(of rows: [(old: Bool, new: Bool, text: String)], at indices: [Int], language: String?) -> [(Int, AttributedString)] {
        guard let colored = colored(indices.map { rows[$0].text }.joined(separator: "\n"), language: language) else { return [] }

        var offset = 0
        return indices.compactMap { index in
            let range = NSRange(location: offset, length: rows[index].text.utf16.count)
            offset = NSMaxRange(range) + 1
            return (try? AttributedString(colored.attributedSubstring(from: range), including: \.uiKit)).map { (index, $0) }
        }
    }

    private nonisolated static func colored(_ text: String, language: String?) -> NSAttributedString? {
        guard let language, text.utf8.count < 200_000, text.split(separator: "\n", omittingEmptySubsequences: false).count <= maxLines else { return nil }

        let name = language == "sh" ? "bash" : language
        let key = "\(name)\n\(text.count)\n\(text.hashValue)"
        if let cached = cache.text(forKey: key) { return cached }

        let spans = CodeHighlighter.spans(in: text, language: name)
        let colored = NSMutableAttributedString(string: text)
        for span in spans where NSMaxRange(span.range) <= colored.length {
            guard let color = SyntaxPalette.color(forCapture: span.capture) else { continue }

            colored.addAttribute(.foregroundColor, value: color, range: span.range)
        }
        let result = spans.isEmpty ? nil : colored
        cache.set(result, forKey: key)
        return result
    }
}

struct HighlightedText: View {
    let text: String
    let language: String?

    @State private var attributed: AttributedString?

    var body: some View {
        Text(attributed ?? AttributedString(text))
            .task(id: text) { attributed = await CodeHighlighting.attributed(text, language: language) }
    }
}
