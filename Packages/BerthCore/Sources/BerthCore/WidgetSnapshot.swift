import Foundation

public nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public static let appGroup = "group.dev.gustaf.berth.remote"
    public static let widgetKind = "dev.gustaf.berth.remote.needsYou"
    public static let maxItems = 20
    private static let key = "widgetSnapshot"

    public var needsYou: [Item]

    public init(needsYou: [Item]) {
        self.needsYou = Array(needsYou.prefix(Self.maxItems))
    }

    public static func load() -> Self? {
        UserDefaults(suiteName: appGroup)?.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }

        UserDefaults(suiteName: Self.appGroup)?.set(data, forKey: Self.key)
    }

    public func applying(pushStatus: String, sessionID: String, title: String) -> Self {
        let others = needsYou.filter { $0.id != sessionID }
        switch pushStatus {
        case "waiting": return Self(needsYou: [Item(id: sessionID, title: title)] + others)
        case "test": return self
        default: return Self(needsYou: others)
        }
    }
}
