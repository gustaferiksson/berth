import Foundation

public struct PullRequestChecks: Sendable, Hashable {
    public enum State: String, Sendable {
        case passed
        case failed
        case running

        public init(_ state: String) {
            if ["SUCCESS", "NEUTRAL", "SKIPPED", "COMPLETED"].contains(state) {
                self = .passed
            } else if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE"].contains(state) {
                self = .failed
            } else {
                self = .running
            }
        }
    }

    public let state: State
    public let passed: Int
    public let failed: Int
    public let running: Int
}

public struct PullRequestDetail: Sendable, Hashable {
    public let checks: PullRequestChecks?
    public let unresolvedThreads: Int
    public var headRefName: String?
    public var reviewDecision: String?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var commits: Int?

    public static let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { headRefName reviewDecision additions deletions changedFiles commits { totalCount } statusCheckRollup { state contexts { checkRunCountsByState { state count } statusContextCountsByState { state count } } } reviewThreads(first: 100) { nodes { isResolved } } } } }"

    private struct Response: Decodable {
        struct Payload: Decodable {
            let repository: Repository?
        }

        struct Repository: Decodable {
            let pullRequest: PullRequest?
        }

        struct PullRequest: Decodable {
            let statusCheckRollup: Rollup?
            let reviewThreads: Threads
            let headRefName: String?
            let reviewDecision: String?
            let additions: Int?
            let deletions: Int?
            let changedFiles: Int?
            let commits: Commits?
        }

        struct Commits: Decodable {
            let totalCount: Int
        }

        struct Rollup: Decodable {
            let state: String
            let contexts: Contexts
        }

        struct Contexts: Decodable {
            let checkRunCountsByState: [StateCount]?
            let statusContextCountsByState: [StateCount]?
        }

        struct StateCount: Decodable {
            let state: String
            let count: Int
        }

        struct Threads: Decodable {
            struct Thread: Decodable {
                let isResolved: Bool
            }

            let nodes: [Thread?]
        }

        let data: Payload?
    }

    public static func arguments(repository: String, number: Int) -> [String]? {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }

        return ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)"]
    }

    public static func parse(_ output: Data) -> Self? {
        guard let pullRequest = (try? JSONDecoder().decode(Response.self, from: output))?.data?.repository?.pullRequest else { return nil }

        let checks = pullRequest.statusCheckRollup.map { rollup in
            let counts = Dictionary(grouping: (rollup.contexts.checkRunCountsByState ?? []) + (rollup.contexts.statusContextCountsByState ?? []), by: { PullRequestChecks.State($0.state) }).mapValues { $0.reduce(0) { $0 + $1.count } }
            return PullRequestChecks(state: PullRequestChecks.State(rollup.state), passed: counts[.passed] ?? 0, failed: counts[.failed] ?? 0, running: counts[.running] ?? 0)
        }

        return Self(checks: checks, unresolvedThreads: pullRequest.reviewThreads.nodes.count(where: { $0?.isResolved == false }), headRefName: pullRequest.headRefName, reviewDecision: pullRequest.reviewDecision, additions: pullRequest.additions, deletions: pullRequest.deletions, changedFiles: pullRequest.changedFiles, commits: pullRequest.commits?.totalCount)
    }
}
