@testable import BerthCore
import Testing

struct PullRequestSelectionTests {
    private struct Candidate: PullRequestCandidate, Equatable {
        let repository: String
        let number: Int
        var head: String?
        var state: PullRequestState = .open
    }

    private func order(_ candidates: [Candidate], current: String? = "acme/billing", branches: [String] = []) -> [Int] {
        PullRequestSelection.order(candidates, currentRepository: current, branches: branches).map(\.number)
    }

    @Test func openAndDraftComeBeforeMergedBeforeClosed() {
        let candidates = [
            Candidate(repository: "acme/billing", number: 1, state: .closed),
            Candidate(repository: "acme/billing", number: 2, state: .merged),
            Candidate(repository: "acme/web", number: 3, state: .draft),
        ]
        #expect(order(candidates) == [3, 2, 1])
    }

    @Test func theCurrentRepositoryBeatsAMatchingHeadElsewhere() {
        let candidates = [
            Candidate(repository: "acme/web", number: 1, head: "feat/a"),
            Candidate(repository: "ACME/Billing", number: 2, head: "feat/b"),
        ]
        #expect(order(candidates, branches: ["feat/a"]) == [2, 1])
    }

    @Test func aRecordedBranchBeatsTheNewestLinkWithinOneRepository() {
        let candidates = [
            Candidate(repository: "acme/billing", number: 3, head: "feat/c"),
            Candidate(repository: "acme/billing", number: 2, head: "feat/b"),
            Candidate(repository: "acme/billing", number: 1, head: "feat/a"),
        ]
        #expect(order(candidates, branches: ["feat/a"]) == [1, 3, 2])
        #expect(order(candidates) == [3, 2, 1])
    }

    @Test func stateOutranksRepositoryAndBranch() {
        let candidates = [
            Candidate(repository: "acme/billing", number: 1, head: "feat/a", state: .merged),
            Candidate(repository: "acme/web", number: 2, state: .open),
        ]
        #expect(order(candidates, branches: ["feat/a"]) == [2, 1])
    }

    @Test func aPullRequestListedTwiceKeepsItsFirstEntry() {
        let candidates = [
            Candidate(repository: "acme/billing", number: 5, state: .draft),
            Candidate(repository: "Acme/Billing", number: 5, state: .open),
            Candidate(repository: "acme/web", number: 5),
        ]
        #expect(PullRequestSelection.order(candidates, currentRepository: nil, branches: []) == [candidates[0], candidates[2]])
    }

    @Test func aClosedPullRequestFromAnEarlierBranchIsDropped() {
        let candidates = [
            Candidate(repository: "acme/billing", number: 1, head: "feat/old", state: .closed),
            Candidate(repository: "acme/billing", number: 2, head: "feat/old", state: .merged),
            Candidate(repository: "acme/billing", number: 3, head: "feat/new", state: .closed),
            Candidate(repository: "acme/billing", number: 4, head: "feat/other", state: .closed),
            Candidate(repository: "acme/billing", number: 5, head: "feat/new", state: .open),
        ]
        let kept = PullRequestSelection.current(candidates, branch: "feat/new") { $0.number == 4 }
        #expect(kept.map(\.number) == [2, 3, 4, 5])
    }
}
