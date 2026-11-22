@testable import BerthCore
import Foundation
import Testing

struct ReviewThreadTests {
    @Test func parsesReviewThreads() throws {
        let output = #"""
        {"data":{"repository":{"pullRequest":{
          "id":"PR_example",
          "reviewThreads":{"nodes":[
            {"id":"open","path":"README.md","line":3,"startLine":2,"diffSide":"RIGHT","isResolved":false,"isOutdated":false,"comments":{"nodes":[
              {"id":"comment-1","author":{"login":"lee"},"body":"Add an example.","createdAt":"2026-05-12T09:00:00Z"},
              null,
              {"id":"comment-2","author":null,"body":"I’ll add one.","createdAt":"2026-05-12T09:15:00.500Z"}
            ]}},
            null,
            {"id":"resolved","path":"README.md","line":8,"diffSide":"RIGHT","isResolved":true,"isOutdated":false,"comments":{"nodes":[
              {"id":"comment-3","author":{"login":"sam"},"body":"Fixed.","createdAt":"invalid"}
            ]}},
            {"id":"outdated","path":"README.md","line":11,"diffSide":"RIGHT","isResolved":false,"isOutdated":true,"comments":{"nodes":[]}},
            {"id":"original","path":"docs/usage.md","line":4,"diffSide":"LEFT","isResolved":false,"isOutdated":false,"comments":{"nodes":null}}
          ]}
        }}}}
        """#
        let detail = try #require(PullRequestDetail.parse(Data(output.utf8)))
        #expect(detail.id == "PR_example")
        #expect(detail.unresolvedThreads == 3)
        #expect(detail.threads.map(\.id) == ["open", "resolved", "outdated", "original"])
        let thread = try #require(detail.threads.first)
        #expect(thread.path == "README.md")
        #expect(thread.line == 3)
        #expect(thread.startLine == 2)
        #expect(thread.side == .modified)
        #expect(thread.comments == [
            ReviewThread.Comment(id: "comment-1", author: "lee", body: "Add an example.", createdAt: Date(timeIntervalSince1970: 1_778_576_400)),
            ReviewThread.Comment(id: "comment-2", author: "ghost", body: "I’ll add one.", createdAt: Date(timeIntervalSince1970: 1_778_577_300.5)),
        ])
        #expect(detail.threads.first { $0.id == "resolved" }?.isResolved == true)
        #expect(detail.threads.first { $0.id == "resolved" }?.comments.first?.createdAt == nil)
        let outdated = try #require(detail.threads.first { $0.id == "outdated" })
        #expect(outdated.isOutdated)
        #expect(outdated.line == nil)
        #expect(detail.threads.first { $0.id == "original" }?.side == .original)
    }

    @Test func replyArgumentsPassBodyAsAStringVariable() {
        let body = "@reviewer: \"example\"\n${value}"
        let arguments = ReviewThread.replyArguments(threadID: "PRRT_example", body: body)
        #expect(Array(arguments.prefix(3)) == ["api", "graphql", "-f"])
        #expect(arguments[3].contains("addPullRequestReviewThreadReply(input:"))
        #expect(arguments[3].contains("pullRequestReviewThreadId: $threadID"))
        #expect(arguments[3].contains("$reviewID: ID!"))
        #expect(arguments[3].contains("pullRequestReviewId: $reviewID"))
        #expect(arguments[3].contains("body: $body"))
        #expect(!arguments[3].contains(body))
        #expect(Array(arguments.dropFirst(4)) == ["-f", "threadID=PRRT_example", "-f", "body=\(body)"])
    }

    @Test func newThreadArgumentsPassASingleModifiedLine() {
        let comment = ReviewComment(id: "local", path: "docs/{owner}/usage.md", line: 3, endLine: 3, text: "@sample\nadd an example", snippet: "")
        let arguments = ReviewThread.newThreadArguments(pullRequestID: "PR_example", comment: comment)
        #expect(Array(arguments.prefix(3)) == ["api", "graphql", "-f"])
        #expect(arguments[3].contains("addPullRequestReviewThread(input:"))
        #expect(arguments[3].contains("pullRequestId: $pullRequestID"))
        #expect(arguments[3].contains("subjectType: LINE"))
        #expect(arguments[3].contains("body: $body"))
        #expect(!arguments[3].contains(comment.text))
        #expect(!arguments[3].contains(comment.path))
        #expect(!arguments[3].contains("startLine"))
        #expect(!arguments[3].contains("startSide"))
        #expect(Array(arguments.dropFirst(4)) == ["-f", "pullRequestID=PR_example", "-f", "path=\(comment.path)", "-F", "line=3", "-f", "side=RIGHT", "-f", "body=\(comment.text)"])
    }

    @Test func newThreadArgumentsPassBothEndsOfAnOriginalRange() {
        let comment = ReviewComment(id: "local", path: "README.md", line: 3, endLine: 5, text: "Explain this range.", snippet: "", side: .original)
        let arguments = ReviewThread.newThreadArguments(pullRequestID: "PR_example", comment: comment)
        #expect(arguments[3].contains("startLine: $startLine"))
        #expect(arguments[3].contains("startSide: $startSide"))
        #expect(Array(arguments.dropFirst(4)) == ["-f", "pullRequestID=PR_example", "-f", "path=README.md", "-F", "line=5", "-f", "side=LEFT", "-f", "body=\(comment.text)", "-F", "startLine=3", "-f", "startSide=LEFT"])
    }

    @Test func promptIncludesTheThreadAndItsComments() {
        let comments = [
            ReviewThread.Comment(id: "comment-1", author: "lee", body: "Add \u{001B}an example.\n\tThanks!", createdAt: nil),
            ReviewThread.Comment(id: "comment-2", author: "ghost", body: "Done\u{007F}.", createdAt: nil),
        ]
        let thread = ReviewThread(id: "open", path: "README.md", line: 3, startLine: nil, side: .modified, isResolved: false, isOutdated: false, comments: comments)
        #expect(ReviewThread.prompt(for: thread) == "Pull request review thread on README.md:3 (unresolved)\n@lee: Add an example.\n\tThanks!\n@ghost: Done.")

        let resolved = ReviewThread(id: "resolved", path: "README.md", line: nil, startLine: nil, side: .original, isResolved: true, isOutdated: true, comments: [])
        #expect(ReviewThread.prompt(for: resolved, repository: (name: "rocket", path: "/src/rocket")) == "Pull request review thread on README.md (resolved) in the rocket repository at /src/rocket")
    }
}
