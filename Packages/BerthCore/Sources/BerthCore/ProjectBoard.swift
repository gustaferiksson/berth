import Foundation

public struct ProjectRef: Sendable, Equatable {
    public let id: String
    public let number: Int
    public let title: String
    public let ownerLogin: String
    public let url: URL
    public let isClosed: Bool
}

public struct ProjectList: Sendable, Equatable {
    public let viewerLogin: String
    public let projects: [ProjectRef]
}

public struct ProjectItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case issue, pullRequest, draft
    }

    public let id: String
    public let projectID: String
    public let kind: Kind
    public let number: Int?
    public let title: String
    public let repository: String?
    public let url: URL?
    public internal(set) var statusName: String?
    public internal(set) var statusOptionID: String?
    public let assignees: [String]
    public let isDraftPullRequest: Bool
    public let updatedAt: Date?

    public var linkKey: String? {
        guard let repository, let number else { return nil }

        return "\(repository.lowercased())#\(number)"
    }
}

public struct ProjectStatusOption: Sendable, Equatable, Decodable {
    public let id: String
    public let name: String
}

public struct ProjectGroup: Sendable, Equatable {
    public let statusName: String
    public let optionID: String?
    public let items: [ProjectItem]
    public let hiddenCount: Int
}

public struct ProjectBoard: Sendable, Equatable {
    public let project: ProjectRef
    public let statusFieldID: String?
    public let statusOptions: [ProjectStatusOption]
    public let items: [ProjectItem]
    public let isTruncated: Bool

    public static let noStatusName = "No Status"

    public func moving(itemID: String, to option: ProjectStatusOption) -> Self {
        let moved = items.map { item in
            guard item.id == itemID else { return item }

            var item = item
            item.statusName = option.name
            item.statusOptionID = option.id
            return item
        }
        return Self(project: project, statusFieldID: statusFieldID, statusOptions: statusOptions, items: moved, isTruncated: isTruncated)
    }

    public func groups(query: String, mineOnly: Bool, login: String) -> [ProjectGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = login.lowercased()
        let optionsByName = Dictionary(statusOptions.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let optionIDs = Set(statusOptions.map(\.id))
        let doneOptionID = statusOptions.last { $0.name.contains(/done|closed|complete/.ignoresCase()) }?.id
        let recentFirst = items.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        var itemsByOption: [String?: [(item: ProjectItem, isMine: Bool)]] = [:]

        for item in recentFirst {
            let isMine = !login.isEmpty && item.assignees.contains { $0.lowercased() == login }
            guard !mineOnly || isMine else { continue }

            let path = item.number.map { "\(item.repository ?? "") #\($0)" } ?? ""
            guard FuzzyMatch.score(query, name: item.title, path: path) != nil else { continue }

            let optionID = item.statusOptionID ?? item.statusName.flatMap { optionsByName[$0] }
            let knownOptionID = optionID.flatMap { optionIDs.contains($0) ? $0 : nil }
            itemsByOption[knownOptionID, default: []].append((item, isMine))
        }

        let statuses: [(name: String, id: String?)] = statusOptions.map { ($0.name, $0.id) } + [(Self.noStatusName, nil)]
        return statuses.compactMap { status in
            guard let items = itemsByOption[status.id] else { return nil }

            let limit = query.isEmpty && status.id != nil && status.id == doneOptionID ? 5 : items.count
            let shown = items.prefix(limit).sorted { $0.isMine && !$1.isMine }
            return ProjectGroup(statusName: status.name, optionID: status.id, items: shown.map(\.item), hiddenCount: items.count - shown.count)
        }
    }
}
