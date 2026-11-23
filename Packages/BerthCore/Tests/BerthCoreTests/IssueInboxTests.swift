@testable import BerthCore
import Foundation
import Testing

struct IssueInboxTests {
    private let now = Date(timeIntervalSince1970: 1_772_366_400)

    private func inbox() throws -> [InboxIssue] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appending(path: "issue-inbox.json")
        return try #require(IssueInbox.parse(Data(contentsOf: url)))
    }

    @Test func deduplicatesIssuesBySearchPriorityAndCountsUniqueOpenPullRequests() throws {
        let issues = try inbox()
        #expect(issues.map(\.id) == ["acme/billing#57", "acme/web#57", "acme/api#15"])
        #expect(issues.map(\.title) == ["Export billing reports", "Update the web dashboard", "Drop the legacy CSV importer"])
        #expect(issues.map(\.openPullRequestCount) == [3, 0, 0])
        #expect(issues.first?.url.absoluteString == "https://github.com/acme/billing/issues/57")
    }

    @Test func emptyQueryHidesOldIssuesAndSearchFindsThem() throws {
        let issues = try inbox()
        let recent = IssueInbox.rank(" \n", in: issues, now: now)
        #expect(recent.issues.map(\.repository) == ["acme/web", "acme/billing"])
        #expect(recent.older == 1)
        #expect(IssueInbox.rank("csv", in: issues, now: now).issues.map(\.number) == [15])
        #expect(IssueInbox.rank("billing #57", in: issues, now: now).issues.map(\.repository) == ["acme/billing"])
    }

    @Test func distinguishesFailuresFromAnEmptyInbox() {
        #expect(IssueInbox.parse(Data("not json".utf8)) == nil)
        #expect(IssueInbox.parse(Data(#"{"data":{"mine":{"nodes":[]}},"errors":[{"message":"Request failed"}]}"#.utf8)) == nil)
        #expect(IssueInbox.parse(Data(#"{"data":{"assigned":{"nodes":[]},"mine":{"nodes":[]},"mentioned":null}}"#.utf8))?.isEmpty == true)
    }

    @Test func sendsThreeLimitedIssueSearchesInOneGraphQLCall() {
        let query = IssueInbox.arguments[3]
        #expect(IssueInbox.arguments.prefix(3) == ["api", "graphql", "-f"])
        #expect(query.matches(of: /sort:updated-desc", type: ISSUE, first: 50/).count == 3)
        #expect(query.contains(#"assigned: search(query: "is:issue is:open archived:false assignee:@me"#))
        #expect(query.contains(#"mine: search(query: "is:issue is:open archived:false author:@me"#))
        #expect(query.contains(#"mentioned: search(query: "is:issue is:open archived:false mentions:@me"#))
        #expect(query.contains("timelineItems(itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT], first: 50)"))
    }
}
