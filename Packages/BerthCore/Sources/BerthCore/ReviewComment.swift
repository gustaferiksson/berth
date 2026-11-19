import Foundation

public struct ReviewComment: Sendable, Hashable, Identifiable {
    public enum Side: Sendable, Hashable {
        case original, modified
    }

    public let id: String
    public let path: String
    public let line: Int
    public let endLine: Int
    public var text: String
    public let snippet: String
    public let side: Side
    public let compare: ReviewCompare?

    public init(id: String, path: String, line: Int, endLine: Int, text: String, snippet: String, side: Side = .modified, compare: ReviewCompare? = .uncommitted) {
        self.id = id
        self.path = path
        self.line = line
        self.endLine = endLine
        self.text = text
        self.snippet = snippet
        self.side = side
        self.compare = compare
    }

    public static func prompt(for comments: [Self], branch: String, base: String, repository: (name: String, path: String)? = nil) -> String {
        let printable = { (text: String) in String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) })) }
        let blocks = comments.map { comment in
            let lines = comment.endLine > comment.line ? "\(comment.line)-\(comment.endLine)" : "\(comment.line)"
            let language = (comment.path as NSString).pathExtension
            return "\(repository.map { "\($0.name):" } ?? "")\(comment.path):\(lines)\(comment.compare == .committed ? " (as committed)" : "")\n```\(language)\n\(printable(comment.snippet))\n```\n\(printable(comment.text))"
        }
        let heading = "Review comments on \(branch) (vs \(base))\(repository.map { " in the \($0.name) repository at \($0.path), paths relative to it" } ?? ""):"
        return ([heading] + blocks).joined(separator: "\n\n")
    }
}
