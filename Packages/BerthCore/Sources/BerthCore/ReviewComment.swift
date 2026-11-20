import Foundation

public struct ReviewComment: Sendable, Hashable, Identifiable {
    public enum Side: Sendable, Hashable {
        case original, modified
    }

    public struct Element: Sendable, Hashable {
        public let url: String
        public let selector: String
        public let html: String
        public let imagePath: String

        public init(url: String, selector: String, html: String, imagePath: String) {
            self.url = url
            self.selector = selector
            self.html = html
            self.imagePath = imagePath
        }
    }

    public let id: String
    public let path: String
    public let line: Int
    public let endLine: Int
    public var text: String
    public let snippet: String
    public let side: Side
    public let compare: ReviewCompare?
    public let element: Element?

    public init(id: String, path: String, line: Int, endLine: Int, text: String, snippet: String, side: Side = .modified, compare: ReviewCompare? = .uncommitted, element: Element? = nil) {
        self.id = id
        self.path = path
        self.line = line
        self.endLine = endLine
        self.text = text
        self.snippet = snippet
        self.side = side
        self.compare = compare
        self.element = element
    }

    public static func prompt(for comments: [Self], branch: String, base: String, repository: (name: String, path: String)? = nil) -> String {
        let printable = { (text: String) in String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) })) }
        let blocks = comments.map { comment in
            if let element = comment.element {
                return "Preview element `\(printable(element.selector))` on \(printable(element.url))\n```html\n\(printable(element.html))\n```\nScreenshot: \(printable(element.imagePath))\n\(printable(comment.text))"
            }

            let lines = comment.endLine > comment.line ? "\(comment.line)-\(comment.endLine)" : "\(comment.line)"
            let language = (comment.path as NSString).pathExtension
            return "\(repository.map { "\($0.name):" } ?? "")\(comment.path):\(lines)\(comment.compare == .committed ? " (as committed)" : "")\n```\(language)\n\(printable(comment.snippet))\n```\n\(printable(comment.text))"
        }
        let heading = "Review comments on \(branch) (vs \(base))\(repository.map { " in the \($0.name) repository at \($0.path), paths relative to it" } ?? ""):"
        return ([heading] + blocks).joined(separator: "\n\n")
    }
}
