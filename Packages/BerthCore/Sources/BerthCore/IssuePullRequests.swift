import Foundation

public struct IssueReference: Sendable, Hashable {
    public let owner: String
    public let name: String
    public let number: Int

    public var repository: String { "\(owner)/\(name)" }

    public var url: URL { URL(string: "https://github.com/\(repository)/issues/\(number)")! }

    public static func parse(_ query: String) -> Self? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = query.wholeMatch(of: /(?i:https:\/\/github\.com\/)([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+)\/issues\/([0-9]+)/)
            ?? query.wholeMatch(of: /([A-Za-z0-9-]+)\/([A-Za-z0-9._-]+)#([0-9]+)/)
        guard let match, let number = Int32(match.3), number > 0 else { return nil }

        return Self(owner: String(match.1), name: String(match.2), number: Int(number))
    }
}

public struct LinkedPullRequest: Sendable, Hashable {
    public let link: PullRequestLink
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let headRefName: String
}

public enum IssuePullRequests {
    public enum LookupError: Error, Sendable {
        case missingCLI
        case requestFailed
        case issueNotFound
        case numberIsPullRequest

        public var message: String {
            switch self {
            case .missingCLI: "GitHub CLI (gh) is unavailable"
            case .requestFailed: "Couldn’t look up the issue with the GitHub CLI (gh)"
            case .issueNotFound: "Issue not found"
            case .numberIsPullRequest: "This number belongs to a pull request"
            }
        }
    }

    static func timelineFields(first: Int, pullRequestDetails: String = "") -> String {
        let pullRequest = "__typename ... on PullRequest { number state repository { nameWithOwner } \(pullRequestDetails) }"
        return """
        timelineItems(itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT], first: \(first)) {
          nodes {
            __typename
            ... on CrossReferencedEvent { source { \(pullRequest) } }
            ... on ConnectedEvent { subject { \(pullRequest) } }
          }
        }
        """
    }

    public static func arguments(issue: IssueReference) -> [String] {
        let timeline = timelineFields(first: 100, pullRequestDetails: "title url isDraft headRefName")
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            issueOrPullRequest(number: $number) { __typename }
            issue(number: $number) { \(timeline) }
          }
        }
        """
        return ["api", "graphql", "-f", "query=\(query)", "--hostname", "github.com", "-f", "owner=\(issue.owner)", "-f", "name=\(issue.name)", "-F", "number=\(issue.number)"]
    }

    struct Timeline: Decodable {
        let nodes: [Event?]

        var subjects: [Subject] {
            nodes.compactMap { event in
                switch event?.type {
                case "CrossReferencedEvent": event?.source
                case "ConnectedEvent": event?.subject
                default: nil
                }
            }
        }
    }

    struct Event: Decodable {
        enum CodingKeys: String, CodingKey {
            case type = "__typename"
            case source, subject
        }

        let type: String
        let source: Subject?
        let subject: Subject?
    }

    struct Subject: Decodable {
        enum CodingKeys: String, CodingKey {
            case type = "__typename"
            case number, title, url, state, isDraft, headRefName, repository
        }

        struct RepositoryName: Decodable {
            let nameWithOwner: String
        }

        let type: String
        let number: Int?
        let title: String?
        let url: URL?
        let state: String?
        let isDraft: Bool?
        let headRefName: String?
        let repository: RepositoryName?

        var openLink: PullRequestLink? {
            guard type == "PullRequest", state == "OPEN", let number, let repository else { return nil }

            return PullRequestLink(repository: repository.nameWithOwner, number: number)
        }
    }

    private struct Response: Decodable {
        struct Payload: Decodable {
            let repository: Repository?
        }

        struct Repository: Decodable {
            let issueOrPullRequest: Subject?
            let issue: Issue?
        }

        struct Issue: Decodable {
            let timelineItems: Timeline
        }

        struct QueryError: Decodable {
            let type: String?
        }

        let data: Payload?
        let errors: [QueryError]?
    }

    public static func parse(_ output: Data) -> Result<[LinkedPullRequest], LookupError> {
        guard let response = try? JSONDecoder().decode(Response.self, from: output) else { return .failure(.requestFailed) }

        let repository = response.data?.repository
        if repository?.issueOrPullRequest?.type == "PullRequest" { return .failure(.numberIsPullRequest) }
        if let errors = response.errors, !errors.isEmpty {
            return .failure(repository?.issue == nil && errors.allSatisfy { $0.type == "NOT_FOUND" } ? .issueNotFound : .requestFailed)
        }
        guard let issue = repository?.issue else { return .failure(.issueNotFound) }

        var seen: Set<PullRequestLink> = []
        let pullRequests = issue.timelineItems.subjects.compactMap { subject -> LinkedPullRequest? in
            guard let link = subject.openLink, let title = subject.title, let url = subject.url,
                  let isDraft = subject.isDraft, let headRefName = subject.headRefName,
                  seen.insert(PullRequestLink(repository: link.repository.lowercased(), number: link.number)).inserted
            else { return nil }

            return LinkedPullRequest(link: link, title: title, url: url, isDraft: isDraft, headRefName: headRefName)
        }
        return .success(pullRequests)
    }
}
