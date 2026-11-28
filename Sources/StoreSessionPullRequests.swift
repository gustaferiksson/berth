import BerthCore
import Foundation

extension Store {
    func rememberingPullRequests(in sessions: [SessionSummary], continued: [String: String], listed: Set<String>) -> [SessionSummary] {
        var memory = pullRequestMemory
        for (old, new) in continued { memory.move(old, to: new) }
        let merged = sessions.map { session in
            var session = session
            session.pullRequests = memory.merged(session.pullRequests, of: session.id)
            return session
        }
        if !merged.isEmpty { memory.prune(keeping: listed.union(Agent.allCases.filter { !Self.isEnabled($0) }.flatMap { listedIDs[$0] ?? [] })) }
        pullRequestMemory = memory
        return merged
    }

    func sessionReviewPullRequests(of sessionID: String, changes: ReviewChanges?, excluding branchNumber: Int?) -> [ReviewPullRequest] {
        var entries = shownReviewPullRequests[sessionID] ?? [:]
        for remembered in pullRequestMemory.rooted(of: sessionID) where entries[remembered.link] == nil {
            guard let root = remembered.root, let pullRequest = linkedPullRequests[remembered.link] else { continue }

            entries[remembered.link] = ReviewPullRequest(location: ReviewPullRequestLocation(link: remembered.link, root: root), pullRequest: pullRequest)
        }
        if let changes, let root = repositoryRoot(ofSession: sessionID),
           let repository = pullRequestBranch(inRoot: root, branch: changes.branch)?.repository.lowercased() {
            for pullRequest in pullRequests(inRoot: nil, of: sessionID, branch: changes.branch) where pullRequest.number != branchNumber {
                let link = PullRequestLink(repository: repository, number: pullRequest.number)
                if entries[link] == nil { entries[link] = ReviewPullRequest(location: ReviewPullRequestLocation(link: link, root: changes.root), pullRequest: pullRequest) }
            }
        }
        return entries.values.sorted { ($0.id.number, $0.id.repository) < ($1.id.number, $1.id.repository) }
    }
}
