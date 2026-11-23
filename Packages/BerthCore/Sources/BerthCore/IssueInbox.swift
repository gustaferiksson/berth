import Foundation

public struct InboxIssue: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, CaseIterable {
        case assigned, mine, mentioned

        public var title: String {
            switch self {
            case .assigned: "Assigned to you"
            case .mine: "Created by you"
            case .mentioned: "Mentioned"
            }
        }
    }

    public struct Label: Sendable, Equatable, Decodable {
        public let name: String
        public let color: String
    }

    public let role: Role
    public let repository: String
    public let number: Int
    public let url: URL
    public let title: String
    public let updatedAt: Date
    public let openPullRequestCount: Int
    public let author: String?
    public let labels: [Label]

    public var id: String { "\(repository)#\(number)" }
}

public enum IssueInbox {
    private static let labelLimit = 4

    public static let arguments: [String] = {
        let fields = "... on Issue { number title url updatedAt author { login } labels(first: \(labelLimit)) { nodes { name color } } repository { nameWithOwner } \(IssuePullRequests.timelineFields(first: 50)) }"
        let aliases = InboxIssue.Role.allCases.map { role in
            let filter = switch role {
            case .assigned: "assignee:@me"
            case .mine: "author:@me"
            case .mentioned: "mentions:@me"
            }

            return "\(role.rawValue): search(query: \"is:issue is:open archived:false \(filter) sort:updated-desc\", type: ISSUE, first: 50) { nodes { \(fields) } }"
        }
        return ["api", "graphql", "-f", "query=query { \(aliases.joined(separator: " ")) }", "--hostname", "github.com"]
    }()

    private struct Response: Decodable {
        struct Search: Decodable {
            let nodes: [Node?]
        }

        struct Author: Decodable {
            let login: String
        }

        struct Labels: Decodable {
            enum CodingKeys: CodingKey {
                case nodes
            }

            let nodes: [InboxIssue.Label]

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                var items = try container.nestedUnkeyedContainer(forKey: .nodes)
                var labels: [InboxIssue.Label] = []
                while !items.isAtEnd, items.currentIndex < IssueInbox.labelLimit {
                    let item = try items.superDecoder()
                    if let label = try? InboxIssue.Label(from: item) { labels.append(label) }
                }

                nodes = labels
            }
        }

        struct Node: Decodable {
            enum CodingKeys: CodingKey {
                case number, title, url, updatedAt, repository, timelineItems, author, labels
            }

            let number: Int?
            let title: String?
            let url: URL?
            let updatedAt: Date?
            let repository: IssuePullRequests.Subject.RepositoryName?
            let timelineItems: IssuePullRequests.Timeline?
            let author: String?
            let labels: [InboxIssue.Label]

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                number = try container.decodeIfPresent(Int.self, forKey: .number)
                title = try container.decodeIfPresent(String.self, forKey: .title)
                url = try container.decodeIfPresent(URL.self, forKey: .url)
                updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
                repository = try container.decodeIfPresent(IssuePullRequests.Subject.RepositoryName.self, forKey: .repository)
                timelineItems = try container.decodeIfPresent(IssuePullRequests.Timeline.self, forKey: .timelineItems)

                author = (try? container.decode(Author.self, forKey: .author))?.login
                labels = (try? container.decode(Labels.self, forKey: .labels))?.nodes ?? []
            }
        }

        struct QueryError: Decodable {
            let message: String
        }

        let data: [String: Search?]?
        let errors: [QueryError]?
    }

    public static func parse(_ output: Data) -> [InboxIssue]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(Response.self, from: output),
              let data = response.data, response.errors?.isEmpty != false else { return nil }

        var seen: Set<PullRequestLink> = []
        return InboxIssue.Role.allCases.flatMap { role in
            ((data[role.rawValue] ?? nil)?.nodes ?? []).compactMap { node -> InboxIssue? in
                guard let node, let repository = node.repository?.nameWithOwner, let number = node.number,
                      let title = node.title, let url = node.url, let updatedAt = node.updatedAt,
                      seen.insert(PullRequestLink(repository: repository.lowercased(), number: number)).inserted
                else { return nil }

                let links = (node.timelineItems?.subjects ?? []).compactMap(\.openLink)
                let count = Set(links.map { PullRequestLink(repository: $0.repository.lowercased(), number: $0.number) }).count
                return InboxIssue(
                    role: role,
                    repository: repository,
                    number: number,
                    url: url,
                    title: title,
                    updatedAt: updatedAt,
                    openPullRequestCount: count,
                    author: node.author,
                    labels: node.labels
                )
            }
        }
    }

    public static func rank(_ query: String, in issues: [InboxIssue], now: Date) -> (issues: [InboxIssue], older: Int) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let recent = issues.filter { now.timeIntervalSince($0.updatedAt) <= PullRequestInbox.recentWindow }
            let grouped = Dictionary(grouping: recent, by: \.role)
            let ordered = InboxIssue.Role.allCases.flatMap { role in
                grouped[role, default: []].sorted { $0.updatedAt > $1.updatedAt }
            }
            return (ordered, issues.count - recent.count)
        }

        let scored = issues.compactMap { issue in
            FuzzyMatch.score(query, name: issue.title, path: "\(issue.repository) #\(issue.number)").map { (score: $0, issue: issue) }
        }
        let ordered = scored.sorted { left, right in
            left.score != right.score ? left.score > right.score : left.issue.updatedAt > right.issue.updatedAt
        }
        return (ordered.map(\.issue), 0)
    }
}
