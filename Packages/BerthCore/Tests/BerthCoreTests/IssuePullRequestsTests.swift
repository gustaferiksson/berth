@testable import BerthCore
import Foundation
import Testing

struct IssuePullRequestsTests {
    private static let invalidReferences = [
        "", "api#10", "acme//api#10", "acme_tools/api#10", "acme/api#0", "acme/api#-1", "acme/api#１２",
        "acme/api#2147483648", "acme/api#10\nacme/web#11", "http://github.com/acme/api/issues/10",
        "https://example.test/acme/api/issues/10", "https://github.com/acme/api/pull/10",
        "https://github.com/acme/api/issues/10?number=11", "https://github.com@host.test/acme/api/issues/10",
        #"acme/api") { viewer { login } } #10"#, "acme/api#10 -f owner=acme-tools", "acme/api%22#10",
    ]

    @Test func parsesURLAndShortReference() throws {
        let reference = try #require(IssueReference.parse(" https://github.com/acme-tools/api.v2_test/issues/10\n"))
        #expect(reference.owner == "acme-tools")
        #expect(reference.name == "api.v2_test")
        #expect(reference.number == 10)
        #expect(IssueReference.parse("acme-tools/api.v2_test#10") == reference)
    }

    @Test(arguments: invalidReferences) func rejectsInvalidReferences(_ query: String) {
        #expect(IssueReference.parse(query) == nil)
    }

    @Test func sendsIssuePartsAsVariables() throws {
        let issue = try #require(IssueReference.parse("acme/api#10"))
        let arguments = IssuePullRequests.arguments(issue: issue)
        #expect(arguments.prefix(3) == ["api", "graphql", "-f"])
        #expect(arguments.suffix(6) == ["-f", "owner=acme", "-f", "name=api", "-F", "number=10"])
        #expect(arguments[3].contains("repository(owner: $owner, name: $name)"))
        #expect(arguments[3].contains("issue(number: $number)"))
        #expect(arguments[3].contains("timelineItems(itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT], first: 100)"))
        #expect(!arguments[3].contains("acme"))
    }

    @Test func parsesUniqueOpenPullRequestsAcrossRepositories() throws {
        let fixture = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appending(path: "issue-pull-requests.json")
        let pullRequests = try IssuePullRequests.parse(Data(contentsOf: fixture)).get()

        #expect(pullRequests.map(\.link) == [
            PullRequestLink(repository: "acme/api", number: 11),
            PullRequestLink(repository: "acme/web", number: 11),
        ])
        #expect(pullRequests.map(\.title) == ["Add the export endpoint", "Add the export button"])
        #expect(pullRequests.map(\.isDraft) == [false, true])
        #expect(pullRequests.first?.headRefName == "feature/exports")
        #expect(pullRequests.first?.url.absoluteString == "https://github.com/acme/api/pull/11")
    }

    @Test func distinguishesEmptyIssuesFromLookupFailures() throws {
        let empty = Data(#"{"data":{"repository":{"issueOrPullRequest":{"__typename":"Issue"},"issue":{"timelineItems":{"nodes":[]}}}}}"#.utf8)
        let missing = Data(#"{"data":{"repository":{"issue":null}},"errors":[{"type":"NOT_FOUND"}]}"#.utf8)
        let pullRequest = Data(#"{"data":{"repository":{"issueOrPullRequest":{"__typename":"PullRequest"},"issue":null}},"errors":[{"type":"NOT_FOUND"}]}"#.utf8)
        let failed = Data(#"{"data":null,"errors":[{"message":"Bad credentials"}]}"#.utf8)

        #expect(try IssuePullRequests.parse(empty).get().isEmpty)
        #expect(IssuePullRequests.parse(missing) == .failure(.issueNotFound))
        #expect(IssuePullRequests.parse(pullRequest) == .failure(.numberIsPullRequest))
        #expect(IssuePullRequests.parse(failed) == .failure(.requestFailed))
    }
}
