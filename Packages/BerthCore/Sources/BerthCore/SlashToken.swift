public enum SlashToken {
    public static func find(in text: String, caret: String.Index) -> (query: String, replacing: Range<String.Index>)? {
        guard caret > text.startIndex, caret <= text.endIndex else { return nil }

        let before = text[..<caret]
        let start = before.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        guard start < caret, text[start] == "/" else { return nil }

        let end = text[caret...].firstIndex(where: \.isWhitespace) ?? text.endIndex
        let replacesSpace = end < text.endIndex && text[end] == " "
        return (String(text[start..<caret]), start..<(replacesSpace ? text.index(after: end) : end))
    }
}
