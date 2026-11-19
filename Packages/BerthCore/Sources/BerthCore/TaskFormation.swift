import Foundation

public struct IssueRef: Codable, Hashable, Sendable {
    public let repository: String
    public let number: Int

    public init(repository: String, number: Int) {
        self.repository = repository.lowercased()
        self.number = number
    }

    public var key: String { "issue:\(repository)#\(number)" }

    public var url: URL? { URL(string: "https://github.com/\(repository)/issues/\(number)") }

    public static func typed(in text: String) -> [Self] {
        guard text.contains("/issues/") else { return [] }

        return text.matches(of: /github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/issues\/([0-9]+)/).compactMap { match in
            Int(match.3).map { Self(repository: "\(match.1)/\(match.2)", number: $0) }
        }
    }
}

extension PullRequestLink {
    var key: String { "pr:\(repository.lowercased())#\(number)" }
}

public struct StoredTask: Codable, Hashable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable {
        case auto, local
    }

    public var id: String
    public var name: String?
    public var issue: IssueRef?
    public var origin: Origin
    public var sessionIDs: [String]
    public var excluded: [String]

    public init(id: String = "task:\(UUID().uuidString.lowercased())", name: String? = nil, issue: IssueRef? = nil, origin: Origin, sessionIDs: [String] = [], excluded: [String] = []) {
        self.id = id
        self.name = name
        self.issue = issue
        self.origin = origin
        self.sessionIDs = sessionIDs
        self.excluded = excluded
    }
}

public struct TaskSession: Sendable {
    public let id: String
    public let lastPrompt: Date
    public let repository: String?
    public let repositories: Set<String>
    public let typedIssues: [IssueRef]
    public let closingIssues: [IssueRef]
    public let pullRequests: [PullRequestLink]
    public let branches: [String]

    public init(id: String, lastPrompt: Date, repository: String?, repositories: Set<String>, typedIssues: [IssueRef] = [], closingIssues: [IssueRef] = [], pullRequests: [PullRequestLink] = [], branches: [String] = []) {
        self.id = id
        self.lastPrompt = lastPrompt
        self.repository = repository
        self.repositories = repositories
        self.typedIssues = typedIssues
        self.closingIssues = closingIssues
        self.pullRequests = pullRequests
        self.branches = branches
    }

    var isSweep: Bool {
        pullRequests.count >= TaskFormation.sweepPullRequests || Set(typedIssues).count >= TaskFormation.sweepIssues
    }

    var issues: [IssueRef] {
        isSweep ? [] : Array(NSOrderedSet(array: typedIssues + closingIssues).array.compactMap { $0 as? IssueRef }.prefix(TaskFormation.maxIssues))
    }

    public var keys: [String] {
        isSweep ? [] : issues.map(\.key) + pullRequests.map(\.key)
    }
}

public struct TaskSuggestion: Hashable, Sendable {
    public let key: String
    public let taskID: String?
    public let sessionIDs: [String]
}

public struct TaskState: Codable, Equatable, Sendable {
    public var version = 1
    public var tasks: [StoredTask] = []
    public var dismissed: Set<String> = []

    public init(tasks: [StoredTask] = [], dismissed: Set<String> = []) {
        self.tasks = tasks
        self.dismissed = dismissed
    }

    public static func stored(_ json: String?) -> (state: Self, unreadable: [String]) {
        guard let json, let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return (Self(), []) }

        let fragments = (object["tasks"] as? [Any] ?? []).compactMap { element in
            (try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        }
        let decoded = fragments.map { (fragment: $0, task: try? JSONDecoder().decode(StoredTask.self, from: Data($0.utf8))) }
        let dismissed = Set(object["dismissed"] as? [String] ?? [])
        return (Self(tasks: decoded.compactMap(\.task), dismissed: dismissed), decoded.filter { $0.task == nil }.map(\.fragment))
    }

    public func storage(keeping unreadable: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let readable = tasks.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
        let dismissedJSON = (try? encoder.encode(dismissed.sorted())).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return #"{"version":\#(version),"tasks":[\#((readable + unreadable).joined(separator: ","))],"dismissed":\#(dismissedJSON)}"#
    }

    public mutating func continuing(_ continued: [String: String]) {
        let follow = { (ids: [String]) in ids.map { continued[$0] ?? $0 }.reduce(into: [String]()) { ids, id in if !ids.contains(id) { ids.append(id) } } }
        for index in tasks.indices {
            tasks[index].sessionIDs = follow(tasks[index].sessionIDs)
            tasks[index].excluded = follow(tasks[index].excluded)
        }
    }

    public mutating func rename(_ id: String, to name: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[index].name = trimmed.isEmpty ? nil : trimmed
    }

    public mutating func remove(_ sessionID: String, from id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        tasks[index].sessionIDs.removeAll { $0 == sessionID }
        if !tasks[index].excluded.contains(sessionID) { tasks[index].excluded.append(sessionID) }
    }

    public mutating func delete(_ id: String, dismissing keys: Set<String>) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }

        tasks.removeAll { $0.id == id }
        if task.origin == .auto { dismissed.formUnion(keys + (task.issue.map { [$0.key] } ?? [])) }
    }

    public mutating func join(_ sessionIDs: [String], to id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        for other in tasks.indices where other != index { tasks[other].sessionIDs.removeAll { sessionIDs.contains($0) } }
        tasks[index].sessionIDs += sessionIDs.filter { !tasks[index].sessionIDs.contains($0) }
        tasks[index].excluded.removeAll { sessionIDs.contains($0) }
    }

    public mutating func makeTask(_ sessionIDs: [String], origin: StoredTask.Origin) {
        let task = StoredTask(origin: origin)
        tasks.append(task)
        join(sessionIDs, to: task.id)
    }
}

public enum TaskFormation {
    static let sweepPullRequests = 6
    static let sweepIssues = 4
    static let maxIssues = 3
    static let genericBranches: Set = ["main", "master", "develop", "dev", "trunk", "wip", "fix", "test", "tmp", "HEAD"]

    public static func form(_ stored: TaskState, sessions: [TaskSession], makeID: () -> String = { "task:\(UUID().uuidString.lowercased())" }) -> (state: TaskState, shown: [StoredTask], suggestions: [TaskSuggestion]) {
        var state = stored
        let byID = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        let ordered = sessions.sorted { ($0.lastPrompt, $1.id) > ($1.lastPrompt, $0.id) }
        for index in state.tasks.indices {
            let task = state.tasks[index]
            state.tasks[index].sessionIDs = task.sessionIDs.filter { byID[$0] != nil && !task.excluded.contains($0) }
            state.tasks[index].excluded = task.excluded.filter { byID[$0] != nil }
        }

        var memberOf = Dictionary(state.tasks.flatMap { task in task.sessionIDs.map { ($0, task.id) } }) { first, _ in first }
        for session in ordered where memberOf[session.id] == nil {
            let allowed = state.tasks.filter { !$0.excluded.contains(session.id) }
            let byIssue = session.issues.lazy.filter { !state.dismissed.contains($0.key) }.compactMap { issue in allowed.first { $0.issue == issue } }.first
            let pullRequests = Set(session.keys).subtracting(state.dismissed)
            let byPullRequest = allowed.filter { task in task.sessionIDs.contains { id in !pullRequests.isDisjoint(with: byID[id]?.pullRequests.map(\.key) ?? []) } }
            let matches = Set((byIssue.map { [$0] } ?? []) + byPullRequest)
            guard matches.count == 1, let task = matches.first, let index = state.tasks.firstIndex(of: task) else { continue }

            state.tasks[index].sessionIDs.append(session.id)
            memberOf[session.id] = task.id
        }

        let candidates = ordered.filter { memberOf[$0.id] == nil }
        let keyed = candidates.map { session in
            let blocked = Set(state.tasks.filter { $0.excluded.contains(session.id) }.flatMap { owned(by: $0, in: byID) })
            return (id: session.id, keys: Set(session.keys).subtracting(state.dismissed).subtracting(blocked))
        }
        let rank = Dictionary(ordered.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let formed = components(of: keyed)
            .map { $0.sorted { rank[$0, default: 0] < rank[$1, default: 0] } }
            .filter { $0.count >= 2 || byID[$0[0]].map { $0.repositories.count >= 2 } == true }
            .sorted { rank[$0[0], default: 0] < rank[$1[0], default: 0] }
        for members in formed {
            let task = StoredTask(id: makeID(), origin: .auto, sessionIDs: members)
            state.tasks.append(task)
            for member in members { memberOf[member] = task.id }
        }

        for index in state.tasks.indices where state.tasks[index].issue == nil {
            let held = Set(state.tasks.compactMap(\.issue))
            let named = ordered.filter { state.tasks[index].sessionIDs.contains($0.id) }.flatMap(\.issues).filter { !state.dismissed.contains($0.key) && !held.contains($0) }
            state.tasks[index].issue = named.max { lhs, rhs in named.count { $0 == lhs } < named.count { $0 == rhs } }
        }

        let isShown = { (task: StoredTask) in
            task.sessionIDs.count >= 2 || task.name != nil || task.origin == .local
                || task.sessionIDs.count == 1 && (byID[task.sessionIDs[0]]?.repositories.count ?? 0) >= 2
        }
        state.tasks.removeAll { task in
            task.origin == .auto && (task.sessionIDs.isEmpty || !isShown(task) && task.excluded.isEmpty)
        }
        let shown = state.tasks.filter(isShown)
        return (state, shown, suggestions(for: ordered, tasks: shown, dismissed: state.dismissed))
    }

    private static func components(of items: [(id: String, keys: Set<String>)]) -> [[String]] {
        var members: [[String]] = []
        var keys: [Set<String>] = []
        for item in items where !item.keys.isEmpty {
            var merged = [item.id]
            var mergedKeys = item.keys
            for index in keys.indices.reversed() where !keys[index].isDisjoint(with: item.keys) {
                merged += members.remove(at: index)
                mergedKeys.formUnion(keys.remove(at: index))
            }
            members.append(merged)
            keys.append(mergedKeys)
        }
        return members
    }

    private static func owned(by task: StoredTask, in sessions: [String: TaskSession]) -> Set<String> {
        Set((task.issue.map { [$0.key] } ?? []) + task.sessionIDs.flatMap { sessions[$0]?.pullRequests.map(\.key) ?? [] })
    }

    private static func suggestions(for sessions: [TaskSession], tasks: [StoredTask], dismissed: Set<String>) -> [TaskSuggestion] {
        let taskOf = Dictionary(tasks.flatMap { task in task.sessionIDs.map { ($0, task) } }) { first, _ in first }
        let swept = sessions.filter { !$0.isSweep }
        let byBranch = Dictionary(grouping: swept.flatMap { session in session.branches.filter { !genericBranches.contains($0) }.map { ($0, session) } }, by: \.0)
        return byBranch.keys.sorted().compactMap { branch in
            let named = byBranch[branch]?.map(\.1) ?? []
            let key = "branch:\(branch)"
            let taskIDs = Set(named.compactMap { taskOf[$0.id]?.id })
            guard !dismissed.contains(key), Set(named.compactMap(\.repository)).count >= 2, taskIDs.count <= 1 else { return nil }

            let task = tasks.first { taskIDs.contains($0.id) }
            let loose = named.filter { taskOf[$0.id] == nil && task?.excluded.contains($0.id) != true }
            guard !loose.isEmpty else { return nil }

            return TaskSuggestion(key: key, taskID: task?.id, sessionIDs: loose.map(\.id))
        }
    }
}

public enum GroupEntry: Hashable, Sendable {
    case session(String)
    case task(String)
}

public struct SessionTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let issue: IssueRef?
    public let sessions: [SessionSummary]

    public init(id: String, title: String, issue: IssueRef?, sessions: [SessionSummary]) {
        self.id = id
        self.title = title
        self.issue = issue
        self.sessions = sessions
    }

    public static func entries(of sessions: [SessionSummary], tasks: [Self]) -> [GroupEntry] {
        let taskOf = Dictionary(tasks.flatMap { task in task.sessions.map { ($0.id, task) } }) { first, _ in first }
        return sessions.compactMap { session in
            guard let task = taskOf[session.id] else { return .session(session.id) }

            return task.sessions.first?.id == session.id ? .task(task.id) : nil
        }
    }
}
