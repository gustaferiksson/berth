import Foundation

public struct ReviewComment: Sendable, Hashable, Codable {
    public let id: String
    public let path: String
    public let line: Int
    public let endLine: Int
    public let text: String
    public let snippet: String

    public static func prompt(for comments: [ReviewComment], branch: String, base: String) -> String {
        let printable = { (text: String) in String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) })) }
        let blocks = comments.map { comment in
            let lines = comment.endLine > comment.line ? "\(comment.line)-\(comment.endLine)" : "\(comment.line)"
            let language = (comment.path as NSString).pathExtension
            return "\(comment.path):\(lines)\n```\(language)\n\(printable(comment.snippet))\n```\n\(printable(comment.text))"
        }
        return (["Review comments on \(branch) (vs \(base)):"] + blocks).joined(separator: "\n\n")
    }
}
