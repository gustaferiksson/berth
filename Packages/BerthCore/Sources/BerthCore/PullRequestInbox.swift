import Foundation

public struct InboxPullRequest: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable, CaseIterable {
        case reviewRequested, mine, assigned

        public var title: String {
            switch self {
            case .reviewRequested: "Review Requested"
            case .mine: "Mine"
            case .assigned: "Assigned"
            }
        }
    }

    public enum ReviewDecision: String, Sendable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    public let role: Role
    public let repository: String
    public let number: Int
    public let url: URL
    public let title: String
    public let branch: String
    public let isDraft: Bool
    public let updatedAt: Date
    public let author: String?
    public let reviewDecision: ReviewDecision?
    public let checks: PullRequestChecks.State?

    public var id: String { "\(repository)#\(number)" }
}

public enum PullRequestInbox {
    public static let recentWindow: TimeInterval = 30 * 86_400

    public static let arguments: [String] = {
        let fields = "... on PullRequest { number title url isDraft updatedAt headRefName reviewDecision author { login } repository { nameWithOwner } statusCheckRollup { state } }"
        let searches: [(InboxPullRequest.Role, String)] = [(.reviewRequested, "review-requested:@me"), (.mine, "author:@me"), (.assigned, "assignee:@me")]
        let aliases = searches.map { role, filter in "\(role.rawValue): search(query: \"is:pr is:open archived:false \(filter) sort:updated-desc\", type: ISSUE, first: 50) { nodes { \(fields) } }" }
        return ["api", "graphql", "-f", "query=query { \(aliases.joined(separator: " ")) }"]
    }()

    private struct Response: Decodable {
        struct Search: Decodable {
            let nodes: [Node?]
        }

        struct Node: Decodable {
            struct Login: Decodable {
                let login: String
            }

            struct Repository: Decodable {
                let nameWithOwner: String
            }

            struct Rollup: Decodable {
                let state: String
            }

            let number: Int?
            let title: String?
            let url: URL?
            let isDraft: Bool?
            let updatedAt: Date?
            let headRefName: String?
            let reviewDecision: String?
            let author: Login?
            let repository: Repository?
            let statusCheckRollup: Rollup?
        }

        let data: [String: Search?]?
    }

    public static func parse(_ output: Data) -> [InboxPullRequest]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let searches = (try? decoder.decode(Response.self, from: output))?.data else { return nil }

        let found = InboxPullRequest.Role.allCases.flatMap { role in
            ((searches[role.rawValue] ?? nil)?.nodes ?? []).compactMap { node -> InboxPullRequest? in
                guard let node, let number = node.number, let title = node.title, let url = node.url, let repository = node.repository?.nameWithOwner else { return nil }

                return InboxPullRequest(
                    role: role,
                    repository: repository,
                    number: number,
                    url: url,
                    title: title,
                    branch: node.headRefName ?? "",
                    isDraft: node.isDraft ?? false,
                    updatedAt: node.updatedAt ?? .distantPast,
                    author: node.author?.login,
                    reviewDecision: node.reviewDecision.flatMap(InboxPullRequest.ReviewDecision.init),
                    checks: node.statusCheckRollup.map { PullRequestChecks.State($0.state) }
                )
            }
        }
        return found.reduce(into: []) { unique, pullRequest in
            if !unique.contains(where: { $0.number == pullRequest.number && $0.repository.lowercased() == pullRequest.repository.lowercased() }) { unique.append(pullRequest) }
        }
    }

    public static func rank(_ query: String, in pullRequests: [InboxPullRequest], now: Date) -> (pullRequests: [InboxPullRequest], older: Int) {
        let query = query.trimmingCharacters(in: .whitespaces)
        let scored = pullRequests.compactMap { pullRequest in
            FuzzyMatch.score(query, name: pullRequest.title, path: "\(pullRequest.repository) #\(pullRequest.number) \(pullRequest.branch) \(pullRequest.author ?? "")").map { (score: $0, pullRequest: pullRequest) }
        }
        let shown = scored.filter { !query.isEmpty || $0.pullRequest.role == .reviewRequested || now.timeIntervalSince($0.pullRequest.updatedAt) <= recentWindow }
        let roles = InboxPullRequest.Role.allCases
        let ordered = shown.sorted { lhs, rhs in
            let left = roles.firstIndex(of: lhs.pullRequest.role) ?? 0
            let right = roles.firstIndex(of: rhs.pullRequest.role) ?? 0
            if left != right { return left < right }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.pullRequest.updatedAt > rhs.pullRequest.updatedAt
        }
        return (ordered.map(\.pullRequest), scored.count - shown.count)
    }
}
