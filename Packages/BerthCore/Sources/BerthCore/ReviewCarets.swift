import Foundation

public enum ReviewCarets {
    public enum Matching: Sendable {
        case wholeWordMatchCase, substringIgnoreCase
    }

    // VS Code's default editor.wordSeparators plus the characters it classes as whitespace.
    private static let wordSeparators = CharacterSet(charactersIn: "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/? \t\r\n")

    public static func normalize(_ ranges: [NSRange], length: Int) -> [NSRange] {
        let clamped = ranges.map { range -> NSRange in
            let location = min(max(range.location, 0), length)
            return NSRange(location: location, length: min(max(range.length, 0), length - location))
        }
        let sorted = clamped.sorted { ($0.location, $0.length) < ($1.location, $1.length) }
        guard let first = sorted.first else { return [NSRange(location: 0, length: 0)] }

        var merged = [first]
        for range in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            let touchesCaret = range.location == NSMaxRange(last) && (range.length == 0 || last.length == 0)
            guard range.location < NSMaxRange(last) || touchesCaret else {
                merged.append(range)
                continue
            }

            merged[merged.count - 1] = NSUnionRange(last, range)
        }
        return merged
    }

    public static func occurrences(of needle: String, in text: NSString, matching: Matching, within limit: NSRange? = nil) -> [NSRange] {
        guard !needle.isEmpty else { return [] }

        let bounds = limit ?? NSRange(location: 0, length: text.length)
        let options: NSString.CompareOptions = matching == .wholeWordMatchCase ? [.literal] : [.literal, .caseInsensitive]
        var found: [NSRange] = []
        var searchStart = bounds.location
        while searchStart < NSMaxRange(bounds) {
            let hit = text.range(of: needle, options: options, range: NSRange(location: searchStart, length: NSMaxRange(bounds) - searchStart))
            guard hit.location != NSNotFound else { break }

            searchStart = NSMaxRange(hit)
            let after = NSMaxRange(hit)
            let isWholeWord = !(hit.location > 0 && isWordCharacter(at: hit.location - 1, in: text)) && (after >= text.length || !isWordCharacter(at: after, in: text))
            if matching == .substringIgnoreCase || isWholeWord { found.append(hit) }
        }
        return found
    }

    public static func nextOccurrence(after location: Int, of needle: String, in text: NSString, matching: Matching) -> NSRange? {
        occurrences(of: needle, in: text, matching: matching, within: NSRange(location: location, length: text.length - location)).first
            ?? occurrences(of: needle, in: text, matching: matching).first
    }

    public static func wordRange(touching location: Int, in text: NSString) -> NSRange? {
        var start = location
        while start > 0, isWordCharacter(at: start - 1, in: text) { start -= 1 }
        var end = location
        while end < text.length, isWordCharacter(at: end, in: text) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        guard let scalar = Unicode.Scalar(text.character(at: index)) else { return true }

        return !wordSeparators.contains(scalar)
    }
}
