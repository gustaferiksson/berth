import Foundation

public enum ProjectQueries {
    public enum Failure: Error, Sendable, Equatable {
        case missingScope, other
    }

    public struct BoardPage: Sendable, Equatable {
        public let statusFieldID: String?
        public let statusOptions: [ProjectStatusOption]
        public let items: [ProjectItem]
        public let hasNextPage: Bool
        public let endCursor: String?
    }

    public static let refreshScopeCommand = "gh auth refresh -s read:project"
    public static let writeScopeCommand = "gh auth refresh -s project"
    public static let itemLimit = 300

    public static let listArguments = [
        "api", "graphql", "-f",
        """
        query=query {
          viewer {
            login
            projectsV2(first: 50) { nodes { ...ProjectFields } }
            organizations(first: 30) {
              nodes { login projectsV2(first: 30) { nodes { ...ProjectFields } } }
            }
          }
        }
        fragment ProjectFields on ProjectV2 {
          id number title closed url owner { ... on User { login } ... on Organization { login } }
        }
        """,
        "--hostname", "github.com",
    ]

    public static func boardArguments(projectID: String, cursor: String?) -> [String] {
        let query = """
        query($projectID: ID!, $cursor: String) {
          node(id: $projectID) {
            ... on ProjectV2 {
              field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } }
              items(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id isArchived
                  fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name optionId } }
                  content {
                    __typename
                    ... on Issue { number title url state updatedAt repository { nameWithOwner } assignees(first: 5) { nodes { login } } }
                    ... on PullRequest { number title url state isDraft updatedAt repository { nameWithOwner } assignees(first: 5) { nodes { login } } }
                    ... on DraftIssue { title assignees(first: 5) { nodes { login } } }
                  }
                }
              }
            }
          }
        }
        """
        let arguments = ["api", "graphql", "-f", "query=\(query)", "-f", "projectID=\(projectID)", "--hostname", "github.com"]
        return arguments + (cursor.map { ["-f", "cursor=\($0)"] } ?? [])
    }

    public static func moveArguments(projectID: String, itemID: String, fieldID: String, optionID: String) -> [String] {
        let query = """
        mutation($projectID: ID!, $itemID: ID!, $fieldID: ID!, $optionID: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $projectID, itemId: $itemID, fieldId: $fieldID, value: { singleSelectOptionId: $optionID }
          }) { projectV2Item { id } }
        }
        """
        return [
            "api", "graphql", "-f", "query=\(query)", "--hostname", "github.com",
            "-f", "projectID=\(projectID)", "-f", "itemID=\(itemID)", "-f", "fieldID=\(fieldID)", "-f", "optionID=\(optionID)",
        ]
    }

    private struct Response<Payload: Decodable>: Decodable {
        let data: Payload?
    }

    private struct ErrorResponse: Decodable {
        struct QueryError: Decodable {
            let type: String?
            let message: String?
        }

        let message: String?
        let errors: [QueryError]?
    }

    private struct Connection<Node: Decodable>: Decodable {
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }

        let nodes: [Node?]?
        let pageInfo: PageInfo?
    }

    private struct Login: Decodable {
        let login: String
    }

    private struct Repository: Decodable {
        let nameWithOwner: String
    }

    private struct ListedProject: Decodable {
        let id: String
        let number: Int
        let title: String
        let closed: Bool
        let url: URL
        let owner: Login?
    }

    private struct ListPayload: Decodable {
        struct Account: Decodable {
            let login: String
            let projectsV2: Connection<ListedProject>?
            let organizations: Connection<Self>?
        }

        let viewer: Account?
    }

    private struct BoardPayload: Decodable {
        struct StatusField: Decodable {
            let id: String?
            let options: [ProjectStatusOption]?
        }

        struct Content: Decodable {
            enum CodingKeys: String, CodingKey {
                case typename = "__typename"
                case number, title, url, state, isDraft, updatedAt, repository, assignees
            }

            let typename: String
            let number: Int?
            let title: String?
            let url: URL?
            let state: String?
            let isDraft: Bool?
            let updatedAt: String?
            let repository: Repository?
            let assignees: Connection<Login>?
        }

        struct Item: Decodable {
            struct Status: Decodable {
                let name: String?
                let optionId: String?
            }

            let id: String
            let isArchived: Bool
            let fieldValueByName: Status?
            let content: Content?
        }

        struct Node: Decodable {
            let field: StatusField?
            let items: Connection<Item>?
        }

        let node: Node?
    }

    public static func failure(_ output: Data, stderr: String = "") -> Failure {
        if let response = try? JSONDecoder().decode(ErrorResponse.self, from: output) {
            if response.errors?.contains(where: { $0.type == "INSUFFICIENT_SCOPES" || $0.message?.contains("read:project") == true }) == true ||
                response.message?.contains("read:project") == true {
                return .missingScope
            }
        } else if String(decoding: output, as: UTF8.self).contains("read:project") {
            return .missingScope
        }
        return stderr.contains("read:project") ? .missingScope : .other
    }

    public static func parseList(_ output: Data, stderr: String = "") -> Result<ProjectList, Failure> {
        guard let viewer = (try? JSONDecoder().decode(Response<ListPayload>.self, from: output))?.data?.viewer else { return .failure(failure(output, stderr: stderr)) }

        var seen: Set<String> = []
        let accounts = [viewer] + (viewer.organizations?.nodes?.compactMap(\.self) ?? [])
        let projects = accounts.flatMap { account in
            (account.projectsV2?.nodes ?? []).compactMap { project -> ProjectRef? in
                guard let project, !project.closed, seen.insert(project.id).inserted else { return nil }

                return ProjectRef(id: project.id, number: project.number, title: project.title, ownerLogin: project.owner?.login ?? account.login, url: project.url, isClosed: project.closed)
            }
        }
        return .success(ProjectList(viewerLogin: viewer.login, projects: projects))
    }

    public static func parseBoardPage(_ output: Data, projectID: String, stderr: String = "") -> Result<BoardPage, Failure> {
        guard let node = (try? JSONDecoder().decode(Response<BoardPayload>.self, from: output))?.data?.node,
              let connection = node.items
        else { return .failure(failure(output, stderr: stderr)) }

        let items = (connection.nodes ?? []).compactMap { item -> ProjectItem? in
            guard let item, !item.isArchived, let content = item.content, let title = content.title,
                  content.state != "CLOSED", content.state != "MERGED"
            else { return nil }

            let kind: ProjectItem.Kind
            switch content.typename {
            case "Issue": kind = .issue
            case "PullRequest": kind = .pullRequest
            case "DraftIssue": kind = .draft
            default: return nil
            }
            return ProjectItem(
                id: item.id, projectID: projectID, kind: kind, number: content.number, title: title, repository: content.repository?.nameWithOwner, url: content.url,
                statusName: item.fieldValueByName?.name, statusOptionID: item.fieldValueByName?.optionId,
                assignees: (content.assignees?.nodes ?? []).compactMap { $0?.login }, isDraftPullRequest: kind == .pullRequest && content.isDraft == true,
                updatedAt: content.updatedAt.flatMap { try? Date.ISO8601FormatStyle().parse($0) }
            )
        }
        return .success(BoardPage(
            statusFieldID: node.field?.id, statusOptions: node.field?.options ?? [], items: items,
            hasNextPage: connection.pageInfo?.hasNextPage ?? false, endCursor: connection.pageInfo?.endCursor
        ))
    }

    public static func mergePages(project: ProjectRef, pages: [BoardPage]) -> ProjectBoard {
        let status = pages.first { $0.statusFieldID != nil }
        let items = pages.flatMap(\.items)
        return ProjectBoard(
            project: project, statusFieldID: status?.statusFieldID, statusOptions: status?.statusOptions ?? [],
            items: Array(items.prefix(itemLimit)), isTruncated: items.count > itemLimit || pages.last?.hasNextPage == true
        )
    }
}
