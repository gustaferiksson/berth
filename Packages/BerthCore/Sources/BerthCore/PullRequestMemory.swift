import Foundation

public struct PullRequestMemory: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let repository: String
        public let number: Int
        public let root: String?

        public var link: PullRequestLink { PullRequestLink(repository: repository, number: number) }
    }

    public static let limit = 100

    private var entries: [String: [Entry]]

    public init(storage: String?) {
        entries = storage.flatMap { try? JSONDecoder().decode([String: [Entry]].self, from: Data($0.utf8)) } ?? [:]
    }

    public var storage: String {
        String(decoding: (try? JSONEncoder().encode(entries)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public func rooted(of session: String) -> [Entry] {
        (entries[session] ?? []).filter { $0.root != nil }
    }

    public mutating func merged(_ links: [PullRequestLink], of session: String) -> [PullRequestLink] {
        let known = entries[session] ?? []
        let fresh = links.map { link in Entry(repository: link.repository, number: link.number, root: known.first { Self.same($0.link, link) }?.root) }
        let kept = Array((fresh + known.filter { old in !links.contains { Self.same(old.link, $0) } }).prefix(Self.limit))
        if !kept.isEmpty, kept != known { entries[session] = kept }
        return kept.map(\.link)
    }

    public mutating func add(_ link: PullRequestLink, root: String, to session: String) {
        let others = (entries[session] ?? []).filter { !Self.same($0.link, link) }
        entries[session] = Array(([Entry(repository: link.repository, number: link.number, root: root)] + others).prefix(Self.limit))
    }

    public mutating func move(_ old: String, to new: String) {
        guard let moved = entries.removeValue(forKey: old) else { return }

        let existing = entries[new] ?? []
        entries[new] = Array((existing + moved.filter { entry in !existing.contains { Self.same($0.link, entry.link) } }).prefix(Self.limit))
    }

    public mutating func prune(keeping sessions: Set<String>) {
        entries = entries.filter { sessions.contains($0.key) }
    }

    private static func same(_ first: PullRequestLink, _ second: PullRequestLink) -> Bool {
        first.number == second.number && first.repository.lowercased() == second.repository.lowercased()
    }
}
