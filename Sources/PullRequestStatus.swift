import BerthCore
import Foundation

nonisolated enum PullRequestState: String, Sendable {
    case open = "Open"
    case draft = "Draft"
    case merged = "Merged"
    case closed = "Closed"
}

nonisolated struct PullRequest: Sendable, Hashable {
    let number: Int
    let url: URL
    let title: String
    let state: PullRequestState
    var baseRefName: String?
    var headRefName: String?
    var checks: PullRequestChecks.State?
    var closingIssues: [ClosingIssue] = []
}

nonisolated enum IssueState: Sendable {
    case open
    case completed
    case notPlanned
}

nonisolated struct ClosingIssue: Sendable, Hashable {
    let ref: IssueRef
    let title: String
    var state: IssueState?
}

nonisolated struct PullRequestBranch: Sendable, Hashable {
    let repository: String
    let branch: String
}

nonisolated enum PullRequestStatus {
    private static let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Response: Decodable {
        struct Payload: Decodable {
            let info: Info?
            let branches: [String: Connection?]?
            let numbers: [String: Node?]?
        }

        struct Info: Decodable {
            struct Ref: Decodable {
                let name: String
            }

            let nameWithOwner: String
            let defaultBranchRef: Ref?
        }

        struct Connection: Decodable {
            let nodes: [Node]
        }

        struct Node: Decodable {
            struct Repository: Decodable {
                let nameWithOwner: String
            }

            struct Rollup: Decodable {
                let state: String
            }

            struct Issue: Decodable {
                let number: Int
                let title: String
                let state: String?
                let stateReason: String?
                let repository: Repository
            }

            struct Closing: Decodable {
                let nodes: [Issue]
            }

            let number: Int
            let url: URL
            let title: String
            let state: String
            let isDraft: Bool
            let baseRefName: String?
            let headRefName: String?
            let headRepository: Repository?
            let statusCheckRollup: Rollup?
            let closingIssuesReferences: Closing?
        }

        let data: Payload?
    }

    static func fetch(_ branches: Set<PullRequestBranch>, linked: Set<PullRequestLink>) async -> (branches: [PullRequestBranch: PullRequest?], linked: [PullRequestLink: PullRequest]) {
        guard let gh else { return ([:], [:]) }

        return await withTaskGroup(of: (branches: [PullRequestBranch: PullRequest?], linked: [PullRequestLink: PullRequest]).self) { group in
            for repository in Set(branches.map(\.repository) + linked.map(\.repository)) {
                let names = branches.filter { $0.repository == repository }.map(\.branch)
                let numbers = linked.filter { $0.repository == repository }.map(\.number)
                group.addTask { fetch(branches: names, numbers: numbers, in: repository, gh: gh) }
            }
            return await group.reduce(into: ([:], [:])) { results, fetched in
                results.branches.merge(fetched.branches) { $1 }
                results.linked.merge(fetched.linked) { $1 }
            }
        }
    }

    private static let nodeFields = "number url title state isDraft baseRefName headRefName headRepository { nameWithOwner } statusCheckRollup { state } closingIssuesReferences(first: 5) { nodes { number title state stateReason repository { nameWithOwner } } }"

    private static func fetch(branches: [String], numbers: [Int], in repository: String, gh: String) -> (branches: [PullRequestBranch: PullRequest?], linked: [PullRequestLink: PullRequest]) {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil }) else { return ([:], [:]) }

        let target = "repository(owner: \"\(parts[0])\", name: \"\(parts[1])\")"
        let variables = (branches.indices.map { "$b\($0): String!" } + numbers.indices.map { "$n\($0): Int!" }).joined(separator: ", ")
        let branchFields = branches.indices.map { "b\($0): pullRequests(headRefName: $b\($0), first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { \(nodeFields) } }" }.joined(separator: " ")
        let numberFields = numbers.indices.map { "n\($0): pullRequest(number: $n\($0)) { \(nodeFields) }" }.joined(separator: " ")
        let query = "query(\(variables)) { info: \(target) { nameWithOwner defaultBranchRef { name } } \(branches.isEmpty ? "" : "branches: \(target) { \(branchFields) }") \(numbers.isEmpty ? "" : "numbers: \(target) { \(numberFields) }") }"
        let arguments = ["api", "graphql", "-f", "query=\(query)"] + branches.enumerated().flatMap { ["-f", "b\($0.offset)=\($0.element)"] } + numbers.enumerated().flatMap { ["-F", "n\($0.offset)=\($0.element)"] }
        guard let output = run(gh, arguments: arguments),
              let payload = (try? JSONDecoder().decode(Response.self, from: output))?.data,
              let info = payload.info
        else { return ([:], [:]) }

        let found = branches.enumerated().reduce(into: [PullRequestBranch: PullRequest?]()) { results, item in
            guard let connection = payload.branches?["b\(item.offset)"] ?? nil else { return }

            let own = connection.nodes.filter { $0.headRepository?.nameWithOwner == info.nameWithOwner }
            let node = item.element == info.defaultBranchRef?.name ? nil : own.first { $0.state == "OPEN" } ?? own.first
            results[PullRequestBranch(repository: repository, branch: item.element)] = .some(node.map(pullRequest))
        }
        let linked = numbers.enumerated().reduce(into: [PullRequestLink: PullRequest]()) { results, item in
            guard let node = payload.numbers?["n\(item.offset)"] ?? nil else { return }

            results[PullRequestLink(repository: repository, number: item.element)] = pullRequest(node)
        }
        return (found, linked)
    }

    private static func pullRequest(_ node: Response.Node) -> PullRequest {
        let state: PullRequestState = node.state == "MERGED" ? .merged : node.state == "CLOSED" ? .closed : node.isDraft ? .draft : .open
        return PullRequest(number: node.number, url: node.url, title: node.title, state: state, baseRefName: node.baseRefName, headRefName: node.headRefName, checks: node.statusCheckRollup.map { PullRequestChecks.State($0.state) }, closingIssues: node.closingIssuesReferences?.nodes.map { ClosingIssue(ref: IssueRef(repository: $0.repository.nameWithOwner, number: $0.number), title: $0.title, state: IssueState(state: $0.state, reason: $0.stateReason)) } ?? [])
    }

    static func inbox() -> [InboxPullRequest]? {
        guard let gh, let output = run(gh, arguments: PullRequestInbox.arguments) else { return nil }

        return PullRequestInbox.parse(output)
    }

    static func detail(repository: String, number: Int) -> PullRequestDetail? {
        guard let gh, let arguments = PullRequestDetail.arguments(repository: repository, number: number), let output = run(gh, arguments: arguments) else { return nil }

        return PullRequestDetail.parse(output)
    }

    private static func run(_ executable: String, arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

extension IssueState {
    nonisolated init?(state: String?, reason: String?) {
        if state == "OPEN" { self = .open } else if state == "CLOSED" { self = reason == "COMPLETED" ? .completed : .notPlanned } else { return nil }
    }
}
