@testable import BerthCore
import Foundation
import Testing

struct PullRequestDetailTests {
    @Test func countsChecksByOutcome() {
        let output = #"{"data":{"repository":{"pullRequest":{"statusCheckRollup":{"state":"PENDING","contexts":{"checkRunCountsByState":[{"state":"SUCCESS","count":4},{"state":"SKIPPED","count":1},{"state":"FAILURE","count":1},{"state":"CANCELLED","count":1},{"state":"IN_PROGRESS","count":2},{"state":"QUEUED","count":1},{"state":"BRAND_NEW_STATE","count":1},{"state":"TIMED_OUT","count":0}],"statusContextCountsByState":[{"state":"SUCCESS","count":1},{"state":"ERROR","count":1},{"state":"PENDING","count":1}]}},"reviewThreads":{"nodes":[]}}}}}"#
        #expect(PullRequestDetail.parse(Data(output.utf8))?.checks == PullRequestChecks(state: .running, passed: 6, failed: 3, running: 5))
    }

    @Test func pullRequestWithoutChecks() {
        let output = #"{"data":{"repository":{"pullRequest":{"statusCheckRollup":null,"reviewThreads":{"nodes":[]}}}}}"#
        #expect(PullRequestDetail.parse(Data(output.utf8)) == PullRequestDetail(checks: nil, id: nil, threads: []))
    }

    @Test func rollupStates() {
        let rollup = { (state: String) in
            PullRequestDetail.parse(Data(#"{"data":{"repository":{"pullRequest":{"statusCheckRollup":{"state":"\#(state)","contexts":{}},"reviewThreads":{"nodes":[]}}}}}"#.utf8))?.checks?.state
        }
        #expect(["SUCCESS", "FAILURE", "ERROR", "EXPECTED"].map(rollup) == [.passed, .failed, .failed, .running])
    }

    @Test func missingPullRequestOrErrorsGiveNothing() {
        #expect(PullRequestDetail.parse(Data(#"{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a PullRequest with the number of 7."}]}"#.utf8)) == nil)
        #expect(PullRequestDetail.parse(Data(#"{"data":null,"errors":[{"message":"Bad credentials"}]}"#.utf8)) == nil)
        #expect(PullRequestDetail.parse(Data("not json".utf8)) == nil)
    }

    @Test func argumentsPassEverythingAsVariables() {
        #expect(PullRequestDetail.arguments(repository: "acme/rocket-app", number: 42) == ["api", "graphql", "-f", "query=\(PullRequestDetail.query)", "-f", "owner=acme", "-f", "name=rocket-app", "-F", "number=42"])
        #expect(PullRequestDetail.arguments(repository: "acme", number: 42) == nil)
    }
}
