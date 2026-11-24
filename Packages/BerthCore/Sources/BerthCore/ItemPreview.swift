import Foundation

public struct ItemPreview: Sendable, Equatable {
    public enum Kind: Sendable {
        case pullRequest, issue
    }

    public enum State: Sendable {
        case open, draft, merged, closed, completed, notPlanned
    }

    public struct Person: Decodable, Sendable, Equatable {
        public let login: String
        public let avatarURL: URL?

        private enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatarUrl"
        }

        public init(login: String, avatarURL: URL? = nil) {
            self.login = login
            self.avatarURL = avatarURL
        }
    }

    public struct Label: Decodable, Sendable, Equatable {
        public let name: String
        public let color: String

        public init(name: String, color: String) {
            self.name = name
            self.color = color
        }
    }

    public struct Reviewer: Sendable, Equatable {
        public enum State: String, Sendable {
            case approved = "APPROVED"
            case changesRequested = "CHANGES_REQUESTED"
            case commented = "COMMENTED"
            case requested
            case dismissed = "DISMISSED"
        }

        public let login: String
        public let state: State

        public init(login: String, state: State) {
            self.login = login
            self.state = state
        }
    }

    public struct Related: Sendable, Equatable {
        public let repository: String
        public let number: Int
        public let title: String
        public let isPullRequest: Bool
        public let state: String

        public init(repository: String, number: Int, title: String, isPullRequest: Bool, state: String) {
            self.repository = repository
            self.number = number
            self.title = title
            self.isPullRequest = isPullRequest
            self.state = state
        }
    }

    public struct Comment: Sendable, Equatable {
        public let author: String?
        public let body: String
        public let createdAt: Date

        public init(author: String?, body: String, createdAt: Date) {
            self.author = author
            self.body = body
            self.createdAt = createdAt
        }
    }

    public let kind: Kind
    public let repository: String
    public let number: Int
    public let url: URL
    public let title: String
    public let state: State
    public let body: String
    public let author: Person?
    public let createdAt: Date
    public let updatedAt: Date
    public let labels: [Label]
    public let assignees: [String]
    public let reviewers: [Reviewer]
    public let reviewDecision: InboxPullRequest.ReviewDecision?
    public let checks: ItemChecks?
    public let additions: Int?
    public let deletions: Int?
    public let changedFiles: Int?
    public let baseRefName: String?
    public let headRefName: String?
    public let related: [Related]
    public let comments: [Comment]
    public let commentCount: Int

    public init(
        kind: Kind,
        repository: String,
        number: Int,
        url: URL,
        title: String,
        state: State,
        body: String = "",
        author: Person? = nil,
        createdAt: Date,
        updatedAt: Date,
        labels: [Label] = [],
        assignees: [String] = [],
        reviewers: [Reviewer] = [],
        reviewDecision: InboxPullRequest.ReviewDecision? = nil,
        checks: ItemChecks? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        changedFiles: Int? = nil,
        baseRefName: String? = nil,
        headRefName: String? = nil,
        related: [Related] = [],
        comments: [Comment] = [],
        commentCount: Int = 0
    ) {
        self.kind = kind
        self.repository = repository
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.body = body
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.labels = labels
        self.assignees = assignees
        self.reviewers = reviewers
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.related = related
        self.comments = comments
        self.commentCount = commentCount
    }
}

public struct ItemChecks: Sendable, Equatable {
    public struct Check: Sendable, Equatable {
        public enum Outcome: Sendable {
            case passed, failed, running, skipped
        }

        public let name: String
        public let outcome: Outcome

        public init(name: String, outcome: Outcome) {
            self.name = name
            self.outcome = outcome
        }
    }

    public let items: [Check]

    public var passed: Int { items.count { $0.outcome == .passed } }
    public var failed: Int { items.count { $0.outcome == .failed } }
    public var running: Int { items.count { $0.outcome == .running } }

    public init(items: [Check]) {
        self.items = items
    }
}

public enum ItemPreviewQuery {
    private static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        issueOrPullRequest(number: $number) {
          __typename
          ... on PullRequest {
            \(commonFields)
            state isDraft merged reviewDecision additions deletions changedFiles baseRefName headRefName
            reviewRequests(first: 10) {
              nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } } }
            }
            latestReviews(first: 10) { nodes { state author { login } } }
            commits(last: 1) {
              nodes { commit { statusCheckRollup { contexts(first: 40) {
                nodes { __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } }
              } } } }
            }
            closingIssuesReferences(first: 5) { nodes { number title state repository { nameWithOwner } } }
          }
          ... on Issue {
            \(commonFields)
            issueState: state
            stateReason
            closedByPullRequestsReferences(first: 5, includeClosedPrs: true) {
              nodes { number title state merged repository { nameWithOwner } }
            }
          }
        }
      }
    }
    """

    private static let commonFields = """
    number title url body createdAt updatedAt
    author { login avatarUrl(size: 64) }
    labels(first: 10) { nodes { name color } }
    assignees(first: 5) { nodes { login } }
    comments(last: 3) { totalCount nodes { author { login } body createdAt } }
    """

    private struct Response: Decodable {
        struct Payload: Decodable {
            let repository: Repository?
        }

        struct Repository: Decodable {
            let nameWithOwner: String?
            let issueOrPullRequest: Node?
        }

        struct QueryError: Decodable {
            let message: String
        }

        let data: Payload?
        let errors: [QueryError]?
    }

    private struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node?]?
        let totalCount: Int?

        var values: [Node] { nodes?.compactMap(\.self) ?? [] }
    }

    private struct Node: Decodable {
        private enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case number, url, title, state, issueState, stateReason, isDraft, merged, body, author, createdAt, updatedAt
            case labels, assignees, reviewRequests, latestReviews, reviewDecision, commits, additions, deletions, changedFiles
            case baseRefName, headRefName, closingIssuesReferences, closedByPullRequestsReferences, comments
        }

        let typeName: String?
        let number: Int?
        let url: URL?
        let title: String?
        let state: String?
        let issueState: String?
        let stateReason: String?
        let isDraft: Bool?
        let merged: Bool?
        let body: String?
        let author: ItemPreview.Person?
        let createdAt: Date?
        let updatedAt: Date?
        let labels: Connection<ItemPreview.Label>?
        let assignees: Connection<ItemPreview.Person>?
        let reviewRequests: Connection<ReviewRequest>?
        let latestReviews: Connection<Review>?
        let reviewDecision: String?
        let commits: Connection<CommitNode>?
        let additions: Int?
        let deletions: Int?
        let changedFiles: Int?
        let baseRefName: String?
        let headRefName: String?
        let closingIssuesReferences: Connection<Reference>?
        let closedByPullRequestsReferences: Connection<Reference>?
        let comments: Connection<Comment>?
    }

    private struct ReviewRequest: Decodable {
        struct Reviewer: Decodable {
            private enum CodingKeys: String, CodingKey {
                case typeName = "__typename"
                case login, name
            }

            let typeName: String?
            let login: String?
            let name: String?
        }

        let requestedReviewer: Reviewer?
    }

    private struct Review: Decodable {
        let state: String?
        let author: ItemPreview.Person?
    }

    private struct CommitNode: Decodable {
        struct Commit: Decodable {
            let statusCheckRollup: Rollup?
        }

        struct Rollup: Decodable {
            let contexts: Connection<CheckContext>?
        }

        let commit: Commit?
    }

    private struct CheckContext: Decodable {
        private enum CodingKeys: String, CodingKey {
            case typeName = "__typename"
            case name, status, conclusion, context, state
        }

        let typeName: String?
        let name: String?
        let status: String?
        let conclusion: String?
        let context: String?
        let state: String?

        var check: ItemChecks.Check? {
            switch typeName {
            case "CheckRun":
                guard let name, let status else { return nil }
                guard status == "COMPLETED" else { return .init(name: name, outcome: .running) }

                let outcome: ItemChecks.Check.Outcome = switch conclusion {
                case "SUCCESS", "NEUTRAL": .passed
                case "SKIPPED": .skipped
                case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED", "STALE": .failed
                default: .skipped
                }
                return .init(name: name, outcome: outcome)

            case "StatusContext":
                guard let context, let state else { return nil }

                let outcome: ItemChecks.Check.Outcome = switch state {
                case "SUCCESS": .passed
                case "FAILURE", "ERROR": .failed
                default: .running
                }
                return .init(name: context, outcome: outcome)

            default:
                return nil
            }
        }
    }

    private struct Reference: Decodable {
        struct Repository: Decodable {
            let nameWithOwner: String?
        }

        let repository: Repository?
        let number: Int?
        let title: String?
        let state: String?
        let merged: Bool?
    }

    private struct Comment: Decodable {
        let author: ItemPreview.Person?
        let body: String?
        let createdAt: Date?
    }

    public static func arguments(repository: String, number: Int) -> [String]? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil }) else { return nil }

        return ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)"]
    }

    public static func parse(_ output: Data) -> ItemPreview? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(Response.self, from: output), response.errors?.isEmpty != false,
              let repository = response.data?.repository, let name = repository.nameWithOwner,
              let node = repository.issueOrPullRequest, let number = node.number, let url = node.url, let title = node.title,
              let state = node.state ?? node.issueState, let createdAt = node.createdAt, let updatedAt = node.updatedAt
        else { return nil }

        let kind: ItemPreview.Kind
        let previewState: ItemPreview.State
        switch node.typeName {
        case "PullRequest":
            kind = .pullRequest
            previewState = switch state {
            case "MERGED": .merged
            case "CLOSED": node.merged == true ? .merged : .closed
            default: node.isDraft == true ? .draft : .open
            }

        case "Issue":
            kind = .issue
            previewState = switch (state, node.stateReason) {
            case ("CLOSED", "COMPLETED"): .completed
            case ("CLOSED", "NOT_PLANNED"): .notPlanned
            case ("CLOSED", _): .closed
            default: .open
            }

        default:
            return nil
        }

        let isPullRequest = kind == .pullRequest
        let contexts = node.commits?.values.last?.commit?.statusCheckRollup?.contexts
        let references = isPullRequest ? node.closingIssuesReferences : node.closedByPullRequestsReferences
        let related = (references?.values ?? []).compactMap { reference -> ItemPreview.Related? in
            guard let repository = reference.repository?.nameWithOwner, let number = reference.number,
                  let title = reference.title, let state = reference.state else { return nil }

            return .init(repository: repository, number: number, title: title, isPullRequest: !isPullRequest, state: reference.merged == true ? "MERGED" : state)
        }
        let comments = (node.comments?.values ?? []).suffix(3).compactMap { comment -> ItemPreview.Comment? in
            guard let body = comment.body, let createdAt = comment.createdAt else { return nil }

            return .init(author: comment.author?.login, body: body, createdAt: createdAt)
        }
        return ItemPreview(
            kind: kind, repository: name, number: number, url: url, title: title, state: previewState, body: node.body ?? "",
            author: node.author, createdAt: createdAt, updatedAt: updatedAt, labels: node.labels?.values ?? [], assignees: node.assignees?.values.map(\.login) ?? [],
            reviewers: isPullRequest ? reviewers(for: node) : [], reviewDecision: node.reviewDecision.flatMap(InboxPullRequest.ReviewDecision.init(rawValue:)),
            checks: contexts.map { ItemChecks(items: $0.values.compactMap(\.check)) }, additions: node.additions, deletions: node.deletions,
            changedFiles: node.changedFiles, baseRefName: node.baseRefName, headRefName: node.headRefName,
            related: related, comments: comments, commentCount: node.comments?.totalCount ?? comments.count
        )
    }

    private static func reviewers(for node: Node) -> [ItemPreview.Reviewer] {
        let requests = node.reviewRequests?.values.compactMap(\.requestedReviewer) ?? []
        let requestedUsers = Set(requests.filter { $0.typeName == "User" }.compactMap { $0.login?.lowercased() })
        let reviews = (node.latestReviews?.values ?? []).compactMap { review -> ItemPreview.Reviewer? in
            guard let login = review.author?.login, !requestedUsers.contains(login.lowercased()),
                  let state = review.state.flatMap(ItemPreview.Reviewer.State.init(rawValue:)) else { return nil }

            return .init(login: login, state: state)
        }
        return reviews + requests.compactMap { request in
            let name = request.typeName == "Team" ? request.name : request.login
            return name.map { ItemPreview.Reviewer(login: $0, state: .requested) }
        }
    }
}
