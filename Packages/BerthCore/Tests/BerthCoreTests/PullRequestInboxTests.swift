@testable import BerthCore
import Foundation
import Testing

struct PullRequestInboxTests {
    private let now = Date(timeIntervalSince1970: 1_772_366_400)

    private func inbox() throws -> [InboxPullRequest] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appending(path: "pull-request-inbox.json")
        return try #require(PullRequestInbox.parse(Data(contentsOf: url)))
    }

    @Test func parsesEachSearchOnceInRoleOrderSkippingEmptyNodes() throws {
        let inbox = try inbox()
        #expect(inbox.map(\.id) == ["acme/web#88", "northwind/infra#415", "acme/billing#212", "acme/web#89", "acme/billing#150", "acme/web#77"])
        #expect(inbox.map(\.role) == [.reviewRequested, .reviewRequested, .mine, .mine, .mine, .assigned])

        let rounding = try #require(inbox.first { $0.number == 212 })
        #expect(rounding.branch == "fix/invoice-rounding")
        #expect(rounding.checks == .failed)
        #expect(rounding.reviewDecision == .changesRequested)
        #expect(rounding.url.absoluteString == "https://github.com/acme/billing/pull/212")
        #expect(rounding.updatedAt == now - 60)

        let dashboard = try #require(inbox.first { $0.number == 89 })
        #expect(dashboard.isDraft)
        #expect(dashboard.checks == nil)
        #expect(inbox.first { $0.number == 415 }?.author == nil)
        #expect(inbox.first { $0.number == 77 }?.checks == .running)
    }

    @Test func failuresGiveNothingButNoMatchesGiveAnEmptyList() {
        #expect(PullRequestInbox.parse(Data(#"{"data":null,"errors":[{"message":"Bad credentials"}]}"#.utf8)) == nil)
        #expect(PullRequestInbox.parse(Data("not json".utf8)) == nil)
        #expect(PullRequestInbox.parse(Data(#"{"data":{"reviewRequested":{"nodes":[]},"mine":{"nodes":[]},"assigned":null}}"#.utf8))?.isEmpty == true)
    }

    @Test func emptyQueryHidesStaleMineAndAssignedButKeepsReviewRequests() throws {
        let ranked = try PullRequestInbox.rank(" ", in: inbox(), now: now)
        #expect(ranked.pullRequests.map(\.number) == [88, 415, 212, 89, 77])
        #expect(ranked.older == 1)
    }

    @Test func typedQueryMatchesOlderPullRequestsWithinTheirSection() throws {
        #expect(try PullRequestInbox.rank("csv", in: inbox(), now: now).pullRequests.map(\.number) == [150])
        #expect(try PullRequestInbox.rank("usage", in: inbox(), now: now).pullRequests.map(\.number) == [88, 89])
        #expect(try PullRequestInbox.rank("billing #212", in: inbox(), now: now).pullRequests.map(\.number) == [212])
        #expect(try PullRequestInbox.rank("kim", in: inbox(), now: now).pullRequests.map(\.number) == [77])
    }

    @Test func queryIsOneGraphQLCallWithThreeSearches() throws {
        let query = try #require(PullRequestInbox.arguments.last)
        #expect(PullRequestInbox.arguments.prefix(3) == ["api", "graphql", "-f"])
        #expect(query.matches(of: /search\(query: "is:pr is:open archived:false/).count == 3)
        #expect(query.contains("reviewRequested: search(query: \"is:pr is:open archived:false review-requested:@me"))
    }
}
