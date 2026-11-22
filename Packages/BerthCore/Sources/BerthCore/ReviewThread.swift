import Foundation

public struct ReviewThread: Sendable, Hashable, Identifiable {
    public struct Comment: Sendable, Hashable {
        public let id: String
        public let author: String
        public let body: String
        public let createdAt: Date?
    }

    public let id: String
    public let path: String
    public let line: Int?
    public let startLine: Int?
    public let side: ReviewComment.Side
    public let isResolved: Bool
    public let isOutdated: Bool
    public let comments: [Comment]

    public static func replyArguments(threadID: String, body: String) -> [String] {
        let query = "mutation($threadID: ID!, $body: String!, $reviewID: ID!) { addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadID, pullRequestReviewId: $reviewID, body: $body}) { comment { id } } }"
        return ["api", "graphql", "-f", "query=\(query)", "-f", "threadID=\(threadID)", "-f", "body=\(body)"]
    }

    public static func newThreadArguments(pullRequestID: String, comment: ReviewComment) -> [String] {
        let side = comment.side == .original ? "LEFT" : "RIGHT"
        let fields = ["-f", "pullRequestID=\(pullRequestID)", "-f", "path=\(comment.path)", "-F", "line=\(comment.endLine)", "-f", "side=\(side)", "-f", "body=\(comment.text)"]
        if comment.endLine <= comment.line {
            let query = "mutation($pullRequestID: ID!, $reviewID: ID, $path: String!, $line: Int!, $side: DiffSide!, $body: String!) { addPullRequestReviewThread(input: {pullRequestId: $pullRequestID, pullRequestReviewId: $reviewID, path: $path, line: $line, side: $side, body: $body, subjectType: LINE}) { thread { id } } }"
            return ["api", "graphql", "-f", "query=\(query)"] + fields
        }

        let query = "mutation($pullRequestID: ID!, $reviewID: ID, $path: String!, $line: Int!, $side: DiffSide!, $startLine: Int!, $startSide: DiffSide!, $body: String!) { addPullRequestReviewThread(input: {pullRequestId: $pullRequestID, pullRequestReviewId: $reviewID, path: $path, line: $line, side: $side, startLine: $startLine, startSide: $startSide, body: $body, subjectType: LINE}) { thread { id } } }"
        return ["api", "graphql", "-f", "query=\(query)"] + fields + ["-F", "startLine=\(comment.line)", "-f", "startSide=\(side)"]
    }

    public static func prompt(for thread: Self, repository: (name: String, path: String)? = nil) -> String {
        let line = thread.line.map { ":\($0)" } ?? ""
        let status = thread.isResolved ? "resolved" : "unresolved"
        let location = repository.map { " in the \($0.name) repository at \($0.path)" } ?? ""
        let heading = "Pull request review thread on \(thread.path)\(line) (\(status))\(location)"
        let comments = thread.comments.map { "@\($0.author): \($0.body)" }
        let text = ([heading] + comments).joined(separator: "\n")
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }))
    }
}
