import Foundation

public enum GroupingMode: String, CaseIterable, Sendable {
    case project, repository, recent

    public var title: String { rawValue.capitalized }
}

public struct FolderRule: Codable, Hashable, Sendable {
    public var path: String
    public var includesSubfolders: Bool

    public init(path: String, includesSubfolders: Bool) {
        self.path = path
        self.includesSubfolders = includesSubfolders
    }

    public func matches(_ folder: String) -> Bool {
        let base = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return folder == base || includesSubfolders && folder.hasPrefix(base == "/" ? base : base + "/")
    }
}

public struct CustomGroup: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rules: [FolderRule]

    public init(id: UUID = UUID(), name: String, rules: [FolderRule]) {
        self.id = id
        self.name = name
        self.rules = rules
    }

    public func matches(_ folder: String) -> Bool {
        rules.contains { $0.matches(folder) }
    }
}

public enum RecentBucket: String, CaseIterable, Sendable {
    case today, yesterday, thisWeek, older

    public var title: String {
        if self == .today { return "Today" }
        if self == .yesterday { return "Yesterday" }
        if self == .thisWeek { return "This Week" }
        return "Older"
    }

    public init(date: Date, now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        self = day >= 0 ? .today : day == -1 ? .yesterday : day >= -6 ? .thisWeek : .older
    }
}

public struct SessionGroup: Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case custom(CustomGroup)
        case folder(String)
        case recent(RecentBucket)
    }

    public let kind: Kind
    public let sessions: [SessionSummary]

    public init(kind: Kind, sessions: [SessionSummary]) {
        self.kind = kind
        self.sessions = sessions
    }

    public var id: String {
        if case let .custom(group) = kind { return "custom:\(group.id.uuidString)" }
        if case let .recent(bucket) = kind { return "recent:\(bucket.rawValue)" }
        return folder ?? ""
    }

    public var title: String {
        if case let .custom(group) = kind { return group.name }
        if case let .recent(bucket) = kind { return bucket.title }
        return URL(filePath: folder ?? "/").lastPathComponent
    }

    public var folder: String? {
        guard case let .folder(folder) = kind else { return nil }
        return folder
    }

    public var lastActivity: Date { sessions.first?.lastActivity ?? .distantPast }
}

public struct SessionGrouping: Sendable {
    public let mode: GroupingMode
    public let customGroups: [CustomGroup]
    public let repositoryRoots: [String: String]
    public let now: Date
    public let calendar: Calendar

    public init(mode: GroupingMode, customGroups: [CustomGroup], repositoryRoots: [String: String], now: Date = .now, calendar: Calendar = .current) {
        self.mode = mode
        self.customGroups = customGroups
        self.repositoryRoots = repositoryRoots
        self.now = now
        self.calendar = calendar
    }

    public func kind(forFolder folder: String, lastActivity: Date) -> SessionGroup.Kind {
        if let group = customGroups.first(where: { $0.matches(folder) }) { return .custom(group) }
        if mode == .recent { return .recent(RecentBucket(date: lastActivity, now: now, calendar: calendar)) }
        return .folder(mode == .repository ? repositoryRoots[folder] ?? folder : folder)
    }

    public func groups(_ sessions: [SessionSummary]) -> [SessionGroup] {
        let byKind = Dictionary(grouping: sessions) { kind(forFolder: $0.cwd, lastActivity: $0.lastActivity) }
            .mapValues { $0.sorted { $0.lastActivity > $1.lastActivity } }
        let custom = customGroups.map { SessionGroup(kind: .custom($0), sessions: byKind[.custom($0)] ?? []) }
        let automatic = byKind.filter { if case .custom = $0.key { false } else { true } }
            .map { SessionGroup(kind: $0.key, sessions: $0.value) }
            .sorted { lhs, rhs in
                guard case let .recent(left) = lhs.kind, case let .recent(right) = rhs.kind else { return lhs.lastActivity > rhs.lastActivity }
                return RecentBucket.allCases.firstIndex(of: left)! < RecentBucket.allCases.firstIndex(of: right)!
            }
        return custom + automatic
    }
}
