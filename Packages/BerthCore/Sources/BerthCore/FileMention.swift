import Foundation

public struct FileMention: Sendable, Hashable, Identifiable {
    public let path: String
    public let exists: Bool

    public var id: String { path }

    public var name: String { URL(filePath: path).lastPathComponent }

    public var folder: String { URL(filePath: path).deletingLastPathComponent().path }
}

public enum FileMentions {
    public struct Occurrence: Sendable, Equatable {
        public let token: Substring
        public let mention: FileMention
    }

    private static let trailingPunctuation = Set(".,;:!?)]}'\"")
    private static let pathPrefixes = ["/", "~/", "./", "../"]
    private static let maxWords = 32

    public static func extract<Source: StringProtocol>(from source: Source, folder: String, exists: (String) -> Bool) -> (text: String, occurrences: [Occurrence]) where Source.SubSequence == Substring {
        let text = source[...]
        let base = text.base
        var occurrences: [Occurrence] = []
        var index = text.startIndex

        while index < text.endIndex {
            defer { index = text.index(after: index) }
            guard text[index] == "@", index == base.startIndex || base[base.index(before: index)].isWhitespace else { continue }

            let start = text.index(after: index)
            guard start < text.endIndex, !text[start].isWhitespace else { continue }

            let line = text[start...].prefix { !$0.isNewline }
            guard let (mention, end) = resolve(line, folder: folder, exists: exists) else { continue }

            occurrences.append(Occurrence(token: text[index..<end], mention: mention))
            index = text.index(before: end)
        }
        return (String(text), occurrences)
    }

    private static func resolve(_ line: Substring, folder: String, exists: (String) -> Bool) -> (FileMention, String.Index)? {
        let ends = line.indices.filter { line[$0].isWhitespace }.prefix(maxWords - 1) + [line.endIndex]
        for end in ends.reversed() {
            let candidate = line[..<end]
            for shown in [candidate, candidate.trimmingTrailing(trailingPunctuation)] where !shown.isEmpty {
                let path = absolutePath(String(shown), folder: folder)
                if exists(path) { return (FileMention(path: path, exists: true), shown.endIndex) }
            }
        }

        guard pathPrefixes.contains(where: line.hasPrefix),
              let token = line.prefixMatch(of: /(?:\\ |[^\s])+/) else { return nil }

        let word = token.output.trimmingTrailing(trailingPunctuation)
        guard word.count > 1 else { return nil }

        return (FileMention(path: absolutePath(String(word), folder: folder), exists: false), word.endIndex)
    }

    private static func absolutePath(_ raw: String, folder: String) -> String {
        let unescaped = raw.replacing("\\ ", with: " ")
        let expanded = (unescaped as NSString).expandingTildeInPath
        return URL(filePath: expanded, relativeTo: URL(filePath: folder, directoryHint: .isDirectory)).standardizedFileURL.path
    }
}

private extension Substring {
    func trimmingTrailing(_ characters: Set<Character>) -> Substring {
        var result = self
        while let last = result.last, characters.contains(last) { result = result.dropLast() }
        return result
    }
}
