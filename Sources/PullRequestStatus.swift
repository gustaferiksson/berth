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
    var checks: PullRequestChecks.State?
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

            let number: Int
            let url: URL
            let title: String
            let state: String
            let isDraft: Bool
            let headRepository: Repository?
            let statusCheckRollup: Rollup?
        }

        let data: Payload?
    }

    static func fetch(_ branches: Set<PullRequestBranch>) async -> [PullRequestBranch: PullRequest?] {
        guard let gh else { return [:] }

        return await withTaskGroup(of: [PullRequestBranch: PullRequest?].self) { group in
            for (repository, branches) in Dictionary(grouping: branches, by: \.repository) {
                group.addTask { fetch(branches.map(\.branch), in: repository, gh: gh) }
            }
            return await group.reduce(into: [:]) { $0.merge($1) { $1 } }
        }
    }

    private static func fetch(_ branches: [String], in repository: String, gh: String) -> [PullRequestBranch: PullRequest?] {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil }) else { return [:] }

        let target = "repository(owner: \"\(parts[0])\", name: \"\(parts[1])\")"
        let variables = branches.indices.map { "$b\($0): String!" }.joined(separator: ", ")
        let fields = branches.indices.map { "b\($0): pullRequests(headRefName: $b\($0), first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number url title state isDraft headRepository { nameWithOwner } statusCheckRollup { state } } }" }.joined(separator: " ")
        let query = "query(\(variables)) { info: \(target) { nameWithOwner defaultBranchRef { name } } branches: \(target) { \(fields) } }"
        let arguments = ["api", "graphql", "-f", "query=\(query)"] + branches.enumerated().flatMap { ["-f", "b\($0.offset)=\($0.element)"] }
        guard let output = run(gh, arguments: arguments),
              let payload = (try? JSONDecoder().decode(Response.self, from: output))?.data,
              let info = payload.info, let connections = payload.branches
        else { return [:] }

        return branches.enumerated().reduce(into: [:]) { results, item in
            guard let connection = connections["b\(item.offset)"] ?? nil else { return }

            let own = connection.nodes.filter { $0.headRepository?.nameWithOwner == info.nameWithOwner }
            let node = item.element == info.defaultBranchRef?.name ? nil : own.first { $0.state == "OPEN" } ?? own.first
            results[PullRequestBranch(repository: repository, branch: item.element)] = .some(node.map { node in
                let state: PullRequestState = node.state == "MERGED" ? .merged : node.state == "CLOSED" ? .closed : node.isDraft ? .draft : .open
                return PullRequest(number: node.number, url: node.url, title: node.title, state: state, checks: node.statusCheckRollup.map { PullRequestChecks.State($0.state) })
            })
        }
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
