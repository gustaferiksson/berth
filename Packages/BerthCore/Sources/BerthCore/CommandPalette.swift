import Foundation

public struct PaletteItem: Hashable, Sendable {
    public enum Section: Int, Comparable, Sendable {
        case openTab, action, recentSession

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let id: String
    public let section: Section
    public let title: String
    public let detail: String

    public init(id: String, section: Section, title: String, detail: String) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
    }
}

public enum CommandPalette {
    public static func rank(_ query: String, items: [PaletteItem], limit: Int = 50) -> [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let scored = items.enumerated().compactMap { index, item -> (index: Int, score: Int, item: PaletteItem)? in
            if query.isEmpty { return item.section == .recentSession ? nil : (index, 0, item) }
            return FuzzyMatch.score(query, name: item.title, path: item.detail).map { (index, $0, item) }
        }
        return scored
            .sorted { ($1.score, $0.item.section, $0.index) < ($0.score, $1.item.section, $1.index) }
            .prefix(query.isEmpty ? scored.count : limit)
            .map(\.item)
    }
}
