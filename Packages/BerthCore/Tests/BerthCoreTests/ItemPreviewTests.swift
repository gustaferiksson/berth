@testable import BerthCore
import Foundation
import Testing

struct ItemPreviewTests {
    @Test func parsesPullRequestPreview() throws {
        let output = """
        {"data":{"repository":{"nameWithOwner":"acme/ledger","issueOrPullRequest":{
          "__typename":"PullRequest","number":42,"url":"https://github.com/acme/ledger/pull/42","title":"Round half up",
          "state":"OPEN","isDraft":true,"merged":false,"body":"**Use decimal rounding**",
          "createdAt":"2026-01-04T12:00:00Z","updatedAt":"2026-01-05T12:00:00Z",
          "author":{"login":"jules","avatarUrl":"https://example.com/jules.png"},
          "labels":{"nodes":[{"name":"billing","color":"b60205"},null]},"assignees":{"nodes":[{"login":"jules"}]},
          "reviewDecision":"APPROVED","additions":12,"deletions":4,"changedFiles":3,"baseRefName":"main","headRefName":"rounding",
          "latestReviews":{"nodes":[{"state":"APPROVED","author":{"login":"nora"}},{"state":"COMMENTED","author":{"login":"eli"}}]},
          "reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"eli"}},{"requestedReviewer":{"__typename":"Team","name":"Payments"}}]},
          "commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
            {"__typename":"CheckRun","name":"Unit","status":"COMPLETED","conclusion":"SUCCESS"},
            {"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"NEUTRAL"},
            {"__typename":"CheckRun","name":"Package","status":"COMPLETED","conclusion":"SKIPPED"},
            {"__typename":"CheckRun","name":"Integration","status":"COMPLETED","conclusion":"TIMED_OUT"},
            {"__typename":"CheckRun","name":"Build","status":"IN_PROGRESS","conclusion":null},
            {"__typename":"StatusContext","context":"Deploy","state":"EXPECTED"},
            {"__typename":"StatusContext","context":"Coverage","state":"ERROR"},
            {"__typename":"StatusContext","context":"Docs","state":"SUCCESS"}
          ]}}}}]},
          "closingIssuesReferences":{"nodes":[{"number":17,"title":"Fix drift","state":"OPEN","repository":{"nameWithOwner":"acme/ledger"}}]},
          "comments":{"totalCount":6,"nodes":[
            {"author":{"login":"nora"},"body":"Looks good","createdAt":"2026-01-05T10:00:00Z"},
            {"author":null,"body":"What about negative values?","createdAt":"2026-01-05T11:00:00Z"},
            {"author":{"login":"jules"},"body":"Added a regression test","createdAt":"2026-01-05T12:00:00Z"}
          ]}
        }}}}
        """
        let preview = try #require(ItemPreviewQuery.parse(Data(output.utf8)))
        #expect(try preview == ItemPreview(
            kind: .pullRequest, repository: "acme/ledger", number: 42, url: #require(URL(string: "https://github.com/acme/ledger/pull/42")),
            title: "Round half up", state: .draft, body: "**Use decimal rounding**",
            author: .init(login: "jules", avatarURL: URL(string: "https://example.com/jules.png")),
            createdAt: Date.ISO8601FormatStyle().parse("2026-01-04T12:00:00Z"),
            updatedAt: Date.ISO8601FormatStyle().parse("2026-01-05T12:00:00Z"),
            labels: [.init(name: "billing", color: "b60205")], assignees: ["jules"],
            reviewers: [.init(login: "nora", state: .approved), .init(login: "eli", state: .requested), .init(login: "Payments", state: .requested)],
            reviewDecision: .approved,
            checks: .init(items: [
                .init(name: "Unit", outcome: .passed), .init(name: "Lint", outcome: .passed), .init(name: "Package", outcome: .skipped),
                .init(name: "Integration", outcome: .failed), .init(name: "Build", outcome: .running), .init(name: "Deploy", outcome: .running),
                .init(name: "Coverage", outcome: .failed), .init(name: "Docs", outcome: .passed),
            ]),
            additions: 12, deletions: 4, changedFiles: 3, baseRefName: "main", headRefName: "rounding",
            related: [.init(repository: "acme/ledger", number: 17, title: "Fix drift", isPullRequest: false, state: "OPEN")],
            comments: [
                .init(author: "nora", body: "Looks good", createdAt: Date.ISO8601FormatStyle().parse("2026-01-05T10:00:00Z")),
                .init(author: nil, body: "What about negative values?", createdAt: Date.ISO8601FormatStyle().parse("2026-01-05T11:00:00Z")),
                .init(author: "jules", body: "Added a regression test", createdAt: Date.ISO8601FormatStyle().parse("2026-01-05T12:00:00Z")),
            ], commentCount: 6
        ))
        #expect(preview.checks?.passed == 3)
        #expect(preview.checks?.failed == 2)
        #expect(preview.checks?.running == 2)
    }

    @Test func parsesIssuePreview() throws {
        let output = """
        {"data":{"repository":{"nameWithOwner":"acme/ledger","issueOrPullRequest":{
          "__typename":"Issue","number":17,"url":"https://github.com/acme/ledger/issues/17","title":"Fix drift",
          "issueState":"CLOSED","stateReason":"COMPLETED","body":"Balance drifts during settlement.","author":null,
          "createdAt":"2026-01-04T12:00:00Z","updatedAt":"2026-01-05T12:00:00Z",
          "labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},
          "closedByPullRequestsReferences":{"nodes":[
            {"number":42,"title":"Round half up","state":"MERGED","merged":true,"repository":{"nameWithOwner":"acme/ledger"}}
          ]},
          "comments":{"totalCount":0,"nodes":[]}
        }}}}
        """
        #expect(try ItemPreviewQuery.parse(Data(output.utf8)) == ItemPreview(
            kind: .issue, repository: "acme/ledger", number: 17, url: #require(URL(string: "https://github.com/acme/ledger/issues/17")),
            title: "Fix drift", state: .completed, body: "Balance drifts during settlement.",
            createdAt: Date.ISO8601FormatStyle().parse("2026-01-04T12:00:00Z"),
            updatedAt: Date.ISO8601FormatStyle().parse("2026-01-05T12:00:00Z"),
            labels: [.init(name: "bug", color: "d73a4a")],
            related: [.init(repository: "acme/ledger", number: 42, title: "Round half up", isPullRequest: true, state: "MERGED")]
        ))
    }

    @Test func missingItemsAndGraphQLErrorsGiveNothing() {
        #expect(ItemPreviewQuery.parse(Data(#"{"data":{"repository":{"nameWithOwner":"acme/ledger","issueOrPullRequest":null}}}"#.utf8)) == nil)
        #expect(ItemPreviewQuery.parse(Data(#"{"data":null,"errors":[{"message":"Bad credentials"}]}"#.utf8)) == nil)
    }

    @Test func validatesRepositoryAndPassesVariables() throws {
        let arguments = try #require(ItemPreviewQuery.arguments(repository: "acme/ledger-v1.2_tool", number: 42))
        #expect(Array(arguments.prefix(3)) == ["api", "graphql", "-f"])
        #expect(arguments[3].contains("issueOrPullRequest(number: $number)"))
        #expect(Array(arguments.suffix(6)) == ["-f", "owner=acme", "-f", "name=ledger-v1.2_tool", "-F", "number=42"])
        for repository in ["acme", "/acme/ledger", "acme//ledger", "acme/ledger/", "acme/led ger", "acme/{ledger}", "/ledger", "acme/"] {
            #expect(ItemPreviewQuery.arguments(repository: repository, number: 42) == nil)
        }
    }
}
