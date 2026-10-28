import BerthCore
import Foundation

nonisolated enum PullRequestState: Sendable {
    case open
    case draft
    case merged
    case closed
}

nonisolated enum PullRequestStatus {
    private static let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    private struct Response: Decodable {
        struct Payload: Decodable {
            let repository: [String: Node?]?
        }

        struct Node: Decodable {
            let state: String
            let isDraft: Bool
        }

        let data: Payload?
    }

    static func fetch(_ links: Set<PullRequestLink>) async -> [URL: PullRequestState] {
        guard let gh else { return [:] }
        return await withTaskGroup(of: [URL: PullRequestState].self) { group in
            for (repository, links) in Dictionary(grouping: links, by: \.repository) {
                group.addTask { fetch(links, in: repository, gh: gh) }
            }
            return await group.reduce(into: [:]) { $0.merge($1) { $1 } }
        }
    }

    private static func fetch(_ links: [PullRequestLink], in repository: String, gh: String) -> [URL: PullRequestState] {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil }) else { return [:] }
        let fields = links.map { "pr\($0.number): pullRequest(number: \($0.number)) { state isDraft }" }.joined(separator: " ")
        let query = "query { repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { \(fields) } }"
        guard let output = run(gh, arguments: ["api", "graphql", "-f", "query=\(query)"]),
              let nodes = (try? JSONDecoder().decode(Response.self, from: output))?.data?.repository
        else { return [:] }
        return links.reduce(into: [:]) { states, link in
            guard let node = nodes["pr\(link.number)"] ?? nil else { return }
            if node.state == "MERGED" { states[link.url] = .merged }
            else if node.state == "CLOSED" { states[link.url] = .closed }
            else { states[link.url] = node.isDraft ? .draft : .open }
        }
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
