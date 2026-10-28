import Foundation

public struct PullRequestLink: Sendable, Hashable {
    public let number: Int
    public let url: URL
    public let repository: String
}

public struct SessionSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let cwd: String
    public let title: String
    public let modified: Date
    public let branch: String?
    public let pullRequest: PullRequestLink?

    public init(id: String, cwd: String, title: String, modified: Date, branch: String? = nil, pullRequest: PullRequestLink? = nil) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.modified = modified
        self.branch = branch
        self.pullRequest = pullRequest
    }
}

public enum Transcript {
    static let headBytes = 32 * 1024
    static let tailBytes = 64 * 1024
    static let maxTitleLength = 120

    public static func summary(of url: URL) -> SessionSummary? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0,
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        let tailOffset = max(0, size - tailBytes)
        guard (try? handle.seek(toOffset: UInt64(tailOffset))) != nil else { return nil }
        let tail = (try? handle.readToEnd()) ?? Data()
        return summary(
            id: url.deletingPathExtension().lastPathComponent,
            modified: modified,
            head: records(in: head, dropFirst: false, dropLast: size > head.count),
            tail: records(in: tail, dropFirst: tailOffset > 0, dropLast: false)
        )
    }

    static func summary(id: String, modified: Date, head: [Record], tail: [Record]) -> SessionSummary? {
        guard let cwd = head.first(where: { $0.cwd != nil })?.cwd ?? tail.first(where: { $0.cwd != nil })?.cwd else { return nil }
        let titleKeys: [KeyPath<Record, String?>] = [\.customTitle, \.aiTitle, \.summary, \.agentName]
        let recordedTitle = titleKeys.lazy.compactMap { key in tail.last { $0[keyPath: key] != nil }?[keyPath: key] }.first
        guard let title = recordedTitle ?? head.lazy.compactMap(\.promptText).first else { return nil }
        let oneLine = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let branch = tail.last { $0.gitBranch != nil }?.gitBranch
        let link = tail.last { $0.type == "pr-link" && $0.prNumber != nil }
        return SessionSummary(
            id: id,
            cwd: cwd,
            title: String(oneLine.prefix(maxTitleLength)),
            modified: modified,
            branch: branch == "HEAD" || branch?.isEmpty == true ? nil : branch,
            pullRequest: link.flatMap { link in
                guard let number = link.prNumber, let url = link.prUrl.flatMap(URL.init(string:)), let repository = link.prRepository else { return nil }
                return PullRequestLink(number: number, url: url, repository: repository)
            }
        )
    }

    static func records(in data: Data, dropFirst: Bool, dropLast: Bool) -> [Record] {
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        let complete = lines.dropFirst(dropFirst ? 1 : 0).dropLast(dropLast ? 1 : 0)
        let decoder = JSONDecoder()
        return complete.compactMap { try? decoder.decode(Record.self, from: Data($0)) }
    }
}

struct Record: Decodable {
    struct Message: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let text = try? container.decode(String.self, forKey: .content) {
                content = [Block(type: "text", text: text)]
            } else {
                content = (try? container.decode([Block].self, forKey: .content)) ?? []
            }
        }

        enum CodingKeys: String, CodingKey { case content }
    }

    let type: String?
    let cwd: String?
    let gitBranch: String?
    let prNumber: Int?
    let prUrl: String?
    let prRepository: String?
    let customTitle: String?
    let aiTitle: String?
    let agentName: String?
    let summary: String?
    let isMeta: Bool?
    let isSidechain: Bool?
    let message: Message?

    var promptText: String? {
        guard type == "user", isMeta != true, isSidechain != true,
              let text = message?.content.first(where: { $0.type == "text" })?.text,
              !text.contains("<command-name>"), !text.contains("<local-command"), !text.hasPrefix("Caveat:")
        else { return nil }
        let stripped = text.replacing(/<[^>]*>/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}
