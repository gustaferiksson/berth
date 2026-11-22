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
    public let id: String?
    public let threads: [ReviewThread]
    public var headRefName: String?
    public var reviewDecision: String?
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    public var commits: Int?

    public var unresolvedThreads: Int { threads.count(where: { !$0.isResolved }) }

    public static let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { id headRefName reviewDecision additions deletions changedFiles commits { totalCount } statusCheckRollup { state contexts { checkRunCountsByState { state count } statusContextCountsByState { state count } } } reviewThreads(first: 100) { nodes { id isResolved isOutdated path line startLine diffSide comments(first: 50) { nodes { id author { login } body createdAt } } } } } } }"

    private struct Response: Decodable {
        struct Payload: Decodable {
            let repository: Repository?
        }

        struct Repository: Decodable {
            let pullRequest: PullRequest?
        }

        struct PullRequest: Decodable {
            let id: String?
            let statusCheckRollup: Rollup?
            let reviewThreads: Connection<Thread>?
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

        struct Connection<Node: Decodable>: Decodable {
            let nodes: [Node?]?
        }

        struct Thread: Decodable {
            let id: String
            let path: String
            let line: Int?
            let startLine: Int?
            let diffSide: String
            let isResolved: Bool
            let isOutdated: Bool
            let comments: Connection<Comment>
        }

        struct Comment: Decodable {
            struct Author: Decodable {
                let login: String
            }

            let id: String
            let author: Author?
            let body: String
            let createdAt: String?
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

        let threads = (pullRequest.reviewThreads?.nodes ?? []).compactMap { thread -> ReviewThread? in
            guard let thread else { return nil }

            let comments = (thread.comments.nodes ?? []).compactMap { comment -> ReviewThread.Comment? in
                guard let comment else { return nil }

                let createdAt = comment.createdAt.flatMap { timestamp in
                    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp)) ?? (try? Date.ISO8601FormatStyle().parse(timestamp))
                }
                return ReviewThread.Comment(id: comment.id, author: comment.author?.login ?? "ghost", body: comment.body, createdAt: createdAt)
            }
            return ReviewThread(id: thread.id, path: thread.path, line: thread.isOutdated ? nil : thread.line, startLine: thread.startLine, side: thread.diffSide == "LEFT" ? .original : .modified, isResolved: thread.isResolved, isOutdated: thread.isOutdated, comments: comments)
        }

        return Self(checks: checks, id: pullRequest.id, threads: threads, headRefName: pullRequest.headRefName, reviewDecision: pullRequest.reviewDecision, additions: pullRequest.additions, deletions: pullRequest.deletions, changedFiles: pullRequest.changedFiles, commits: pullRequest.commits?.totalCount)
    }
}
