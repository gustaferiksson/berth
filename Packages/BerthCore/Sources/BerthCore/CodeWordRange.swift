import Foundation

public enum CodeWordRange {
    private enum Kind {
        case identifier, space, lineBreak, punctuation
    }

    public static func expand(_ proposed: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return proposed }

        let first = min(max(proposed.location, 0), text.length - 1)
        let last = min(max(NSMaxRange(proposed) - 1, first), text.length - 1)
        return NSUnionRange(run(around: first, in: text), run(around: last, in: text))
    }

    private static func run(around index: Int, in text: NSString) -> NSRange {
        let kind = kind(at: index, in: text)
        guard kind != .lineBreak else { return NSRange(location: index, length: 1) }

        var start = index
        var end = index + 1
        while start > 0, self.kind(at: start - 1, in: text) == kind { start -= 1 }
        while end < text.length, self.kind(at: end, in: text) == kind { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func kind(at index: Int, in text: NSString) -> Kind {
        guard let scalar = Unicode.Scalar(text.character(at: index)) else { return .identifier }

        if scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar) { return .identifier }
        if CharacterSet.newlines.contains(scalar) { return .lineBreak }
        if CharacterSet.whitespaces.contains(scalar) { return .space }
        return .punctuation
    }
}
