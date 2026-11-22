import Foundation

public struct GraphRef: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case head
        case branch
        case remote
        case tag
    }

    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

public struct GraphCommit: Sendable, Hashable {
    public let sha: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let refs: [GraphRef]
    public let subject: String

    public init(sha: String, parents: [String], author: String, date: Date, refs: [GraphRef], subject: String) {
        self.sha = sha
        self.parents = parents
        self.author = author
        self.date = date
        self.refs = refs
        self.subject = subject
    }

    public static func parse(_ record: Data) -> Self? {
        let fields = record.split(separator: 0x1F, maxSplits: 5, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard fields.count == 6, !fields[0].isEmpty, let time = TimeInterval(fields[3]), time.isFinite else { return nil }

        let refs = fields[4].components(separatedBy: ", ").compactMap { entry -> GraphRef? in
            if entry == "HEAD" { return GraphRef(name: entry, kind: .head) }
            if entry.hasPrefix("HEAD -> ") {
                let name = entry.dropFirst("HEAD -> ".count)
                return GraphRef(name: String(name.hasPrefix("refs/heads/") ? name.dropFirst("refs/heads/".count) : name), kind: .head)
            }
            if entry.hasPrefix("tag: ") {
                let name = entry.dropFirst("tag: ".count)
                return GraphRef(name: String(name.hasPrefix("refs/tags/") ? name.dropFirst("refs/tags/".count) : name), kind: .tag)
            }
            if entry.hasPrefix("refs/heads/") { return GraphRef(name: String(entry.dropFirst("refs/heads/".count)), kind: .branch) }
            if entry.hasSuffix("/HEAD") || entry.isEmpty { return nil }
            if entry.hasPrefix("refs/remotes/") { return GraphRef(name: String(entry.dropFirst("refs/remotes/".count)), kind: .remote) }
            if entry.hasPrefix("refs/") { return nil }
            return GraphRef(name: entry, kind: entry.contains("/") ? .remote : .branch)
        }
        return Self(sha: fields[0], parents: fields[1].split(separator: " ").map(String.init), author: fields[2], date: Date(timeIntervalSince1970: time), refs: refs, subject: fields[5])
    }
}

public struct GraphRow: Sendable, Hashable {
    public let sha: String
    public let lane: Int
    public let laneCount: Int
    public let through: [Int]
    public let merges: [Int]
    public let entersFromAbove: Bool
    public let parentLanes: [Int]
}

public enum ReviewGraph {
    public static func layout(_ commits: [GraphCommit]) -> [GraphRow] {
        var lanes: [String?] = []
        return commits.map { commit in
            let matches = lanes.indices.filter { lanes[$0] == commit.sha }
            let lane = matches.first ?? lanes.firstIndex(of: nil) ?? lanes.count
            if lane == lanes.count { lanes.append(nil) }
            for match in matches { lanes[match] = nil }
            let through = lanes.indices.filter { lanes[$0] != nil }

            let parentLanes = commit.parents.enumerated().map { index, parent in
                if let occupied = lanes.firstIndex(of: parent) { return occupied }

                let destination = index == 0 ? lane : lanes.indices.first { $0 != lane && lanes[$0] == nil } ?? lanes.count
                if destination == lanes.count { lanes.append(parent) } else { lanes[destination] = parent }
                return destination
            }
            let laneCount = max(lane, through.last ?? lane, matches.last ?? lane, parentLanes.max() ?? lane) + 1
            while !lanes.isEmpty, lanes.last == .some(nil) { lanes.removeLast() }
            return GraphRow(sha: commit.sha, lane: lane, laneCount: laneCount, through: through, merges: Array(matches.dropFirst()), entersFromAbove: !matches.isEmpty, parentLanes: parentLanes)
        }
    }
}
