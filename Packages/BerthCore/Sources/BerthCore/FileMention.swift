import Foundation

public struct FileMention: Sendable, Hashable, Identifiable {
    public let path: String
    public let exists: Bool

    public var id: String { path }

    public var name: String { URL(filePath: path).lastPathComponent }

    public var folder: String { URL(filePath: path).deletingLastPathComponent().path }
}

public enum FileMentions {
    private static let trailingPunctuation = Set(".,;:!?)]}'\"")
    private static let pathPrefixes = ["/", "~/", "./", "../"]
    private static let maxWords = 32

    public static func extract(from text: String, folder: String, exists: (String) -> Bool) -> (text: String, mentions: [FileMention]) {
        var output = ""
        var mentions: [FileMention] = []
        var cursor = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            defer { index = text.index(after: index) }
            guard text[index] == "@", index == text.startIndex || text[text.index(before: index)].isWhitespace else { continue }

            let start = text.index(after: index)
            guard start < text.endIndex, !text[start].isWhitespace else { continue }

            let line = text[start...].prefix { !$0.isNewline }
            guard let (mention, end) = resolve(line, folder: folder, exists: exists) else { continue }

            output += text[cursor..<index]
            let isEdge = output.allSatisfy(\.isWhitespace) || text[end...].allSatisfy(\.isWhitespace)
            if !isEdge { output += "@" + mention.name }
            if !mentions.contains(mention) { mentions.append(mention) }
            cursor = end
            index = text.index(before: end)
        }
        output += text[cursor...]
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), mentions)
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

        guard pathPrefixes.contains(where: line.hasPrefix) else { return nil }

        let word = line.prefix { !$0.isWhitespace }.trimmingTrailing(trailingPunctuation)
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
