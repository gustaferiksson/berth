@testable import BerthCore
import Foundation
import Testing

struct PullRequestOwnReviewTests {
    private func output(viewer: String = "margo", reviews: String) -> Data {
        Data(#"{"data":{"viewer":{"login":"\#(viewer)"},"repository":{"pullRequest":{"reviews":{"nodes":[\#(reviews)]}}}}}"#.utf8)
    }

    @Test func takesTheViewersLatestSubmittedReviewCommit() {
        let reviews = """
        {"submittedAt":"2026-11-20T09:00:00Z","author":{"login":"margo"},"commit":{"oid":"1111111111111111111111111111111111111111"}},
        {"submittedAt":"2026-11-25T09:00:00Z","author":{"login":"lee"},"commit":{"oid":"3333333333333333333333333333333333333333"}},
        {"submittedAt":"2026-11-22T12:30:00Z","author":{"login":"margo"},"commit":{"oid":"2222222222222222222222222222222222222222"}},
        {"submittedAt":null,"author":{"login":"margo"},"commit":{"oid":"4444444444444444444444444444444444444444"}},
        {"submittedAt":"2026-11-26T08:00:00Z","author":null,"commit":null},
        null
        """
        let review = PullRequestOwnReview.parse(output(reviews: reviews))
        #expect(review == PullRequestOwnReview(commit: "2222222222222222222222222222222222222222", date: Date(timeIntervalSince1970: 1_795_350_600)))
    }

    @Test func noReviewByTheViewerOrBadPayloadsGiveNothing() {
        #expect(PullRequestOwnReview.parse(output(reviews: #"{"submittedAt":"2026-11-25T09:00:00Z","author":{"login":"lee"},"commit":{"oid":"3"}}"#)) == nil)
        #expect(PullRequestOwnReview.parse(output(reviews: "")) == nil)
        #expect(PullRequestOwnReview.parse(Data(#"{"data":null,"errors":[{"message":"Bad credentials"}]}"#.utf8)) == nil)
        #expect(PullRequestOwnReview.parse(Data("not json".utf8)) == nil)
    }

    @Test func argumentsPassEverythingAsVariables() {
        #expect(PullRequestOwnReview.arguments(repository: "acme/rocket-app", number: 7) == ["api", "graphql", "-f", "query=\(PullRequestOwnReview.query)", "-f", "owner=acme", "-f", "name=rocket-app", "-F", "number=7"])
        #expect(PullRequestOwnReview.arguments(repository: "acme", number: 7) == nil)
    }
}
