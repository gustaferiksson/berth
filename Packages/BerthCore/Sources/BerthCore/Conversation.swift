import Foundation

public struct ToolCall: Identifiable, Sendable {
    public let use: RemoteEntry
    public let result: RemoteEntry?

    public init(use: RemoteEntry, result: RemoteEntry?) {
        self.use = use
        self.result = result
    }

    public var id: String { use.id }

    public var kind: ToolKind { ToolKind(name: use.name ?? "") }

    public var isBackgroundShell: Bool { kind == .command && result?.text.contains("running in background with ID") == true }

    public var isCard: Bool { kind == .agent || isBackgroundShell }

    public var isAsyncLaunch: Bool { result?.text.hasPrefix("Async agent launched") == true }

    public var cardTitle: String { use.detail.flatMap { $0.isEmpty ? nil : $0 } ?? use.command.map { String($0.prefix { $0 != "\n" }) } ?? (kind == .agent ? "Agent" : "Background shell") }

    public var agentID: String? {
        result?.text.firstMatch(of: /agentId:\s*([A-Za-z0-9_-]+)/).map { String($0.1) }
    }

    public var agentType: String? {
        (try? JSONSerialization.jsonObject(with: Data(use.text.utf8)) as? [String: Any])?["subagent_type"] as? String
    }

    public var verb: (past: String, present: String) {
        switch use.name {
        case "Write": ("Wrote", "Writing")
        case "WebSearch": ("Searched the web for", "Searching the web for")
        case "WebFetch": ("Fetched", "Fetching")
        default: kind.verb
        }
    }

    public var subject: String {
        if let command = use.command { return String(command.prefix { $0 != "\n" }) }
        if let path = use.filePath { return URL(filePath: path).lastPathComponent }
        if use.name == "WebFetch", let host = use.detail.flatMap(URL.init(string:))?.host() { return host }
        if kind == .other { return (use.name ?? "").components(separatedBy: "__").last ?? "" }
        return kind == .todo ? "" : use.detail ?? ""
    }

    public static func summary(of calls: [Self]) -> String {
        let grouped = Dictionary(grouping: calls, by: \.kind)
        let order = calls.map(\.kind).reduce(into: [ToolKind]()) { kinds, kind in
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        let top = order.sorted { grouped[$0, default: []].count > grouped[$1, default: []].count }.prefix(order.count > 3 ? 2 : 3)
        let shown = order.filter(top.contains)
        let rest = calls.count - shown.map { grouped[$0, default: []].count }.reduce(0, +)
        let phrases = shown.map { $0.phrase(for: grouped[$0, default: []]) } + (rest > 0 ? ["performed \(rest) other \(rest == 1 ? "action" : "actions")"] : [])
        let sentence = phrases.count < 3 ? phrases.joined(separator: " and ") : phrases.dropLast().joined(separator: ", ") + ", and " + (phrases.last ?? "")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}

public enum ToolKind: Sendable {
    case command, read, edit, search, web, agent, todo, question, other

    public init(name: String) {
        self = switch name {
        case "Bash", "BashOutput": .command
        case "Read", "NotebookRead": .read
        case "Edit", "MultiEdit", "Write", "NotebookEdit": .edit
        case "Grep", "Glob": .search
        case "WebSearch", "WebFetch": .web
        case "Agent", "Task": .agent
        case "TodoWrite": .todo
        case "AskUserQuestion": .question
        default: .other
        }
    }

    public var icon: String {
        switch self {
        case .command: "terminal"
        case .read: "eye"
        case .edit: "square.and.pencil"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .agent: "person.2"
        case .todo: "checklist"
        case .question: "questionmark.bubble"
        case .other: "hammer"
        }
    }

    public var verb: (past: String, present: String) {
        switch self {
        case .command: ("Ran", "Running")
        case .read: ("Read", "Reading")
        case .edit: ("Edited", "Editing")
        case .search, .web: ("Searched for", "Searching for")
        case .agent: ("Ran agent", "Running agent")
        case .todo: ("Updated the todo list", "Updating the todo list")
        case .question: ("Asked", "Asking")
        case .other: ("Used", "Using")
        }
    }

    public func phrase(for calls: [ToolCall]) -> String {
        let count = self == .edit ? Set(calls.map { $0.use.filePath ?? $0.id }).count : calls.count
        return switch self {
        case .command: "ran \(count) \(count == 1 ? "command" : "commands")"
        case .read: "read \(count) \(count == 1 ? "file" : "files")"
        case .edit: "edited \(count) \(count == 1 ? "file" : "files")"
        case .search: "searched code \(count == 1 ? "once" : "\(count) times")"
        case .web: "searched the web \(count == 1 ? "once" : "\(count) times")"
        case .agent: "ran \(count) \(count == 1 ? "agent" : "agents")"
        case .todo: "updated the todo list"
        case .question: "asked \(count) \(count == 1 ? "question" : "questions")"
        case .other: "used \(count) \(count == 1 ? "tool" : "tools")"
        }
    }
}

public enum LiveCall: Equatable, Sendable {
    case running(String)
    case waiting(String)

    public var id: String {
        switch self {
        case let .running(id), let .waiting(id): id
        }
    }
}

public enum TurnPart: Identifiable, Sendable {
    case reply(RemoteEntry)
    case work([ToolCall])
    case cards([ToolCall])

    public var id: String {
        switch self {
        case let .reply(entry): entry.id
        case let .work(calls), let .cards(calls): calls.first?.id ?? ""
        }
    }

    public var isCards: Bool {
        if case .cards = self { true } else { false }
    }

    public var isWork: Bool {
        if case .work = self { true } else { false }
    }
}

public struct FileChanges: Sendable {
    public let files: Int
    public let paths: [String]
    public let added: Int?
    public let removed: Int?
}

public struct Turn: Identifiable, Sendable {
    public let id: String
    public var prompt: RemoteEntry?
    public var parts: [TurnPart] = []
    public var end: Date?
    public var isInterrupted = false

    public init(id: String, prompt: RemoteEntry?, parts: [TurnPart] = [], end: Date? = nil, isInterrupted: Bool = false) {
        self.id = id
        self.prompt = prompt
        self.parts = parts
        self.end = end
        self.isInterrupted = isInterrupted
    }

    public var openCall: ToolCall? {
        let calls: [ToolCall] = switch parts.last {
        case let .work(calls), let .cards(calls): calls
        default: []
        }
        guard let call = calls.last, call.result == nil else { return nil }

        return call
    }

    public var fileChanges: FileChanges? {
        let edits = parts.flatMap { part -> [ToolCall] in
            guard case let .work(calls) = part else { return [] }

            return calls.filter { $0.kind == .edit && $0.result != nil && $0.result?.isError != true }
        }
        guard !edits.isEmpty else { return nil }

        let lines = { (text: String?) in (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        let isCounted = edits.allSatisfy { $0.use.name == "Edit" && $0.use.oldText != nil && $0.use.newText != nil }
        let diffs = edits.map { lines($0.use.newText).difference(from: lines($0.use.oldText)) }
        return FileChanges(
            files: Set(edits.map { $0.use.filePath ?? $0.id }).count,
            paths: edits.compactMap(\.use.filePath).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
            added: isCounted ? diffs.map(\.insertions.count).reduce(0, +) : nil,
            removed: isCounted ? diffs.map(\.removals.count).reduce(0, +) : nil
        )
    }

    public var duration: Duration? {
        guard let start = prompt?.date, let end, end > start else { return nil }

        return .seconds(end.timeIntervalSince(start).rounded())
    }

    // A Code Mode script's inner calls follow its REPL and Poll records as virtual records; the TUI shows those, not the wrapper
    static func scriptsWithInnerCalls(in entries: [RemoteEntry]) -> Set<String> {
        var scripts = Set<String>()
        var current: String?
        for entry in entries {
            if entry.kind == .prompt { current = nil }

            guard entry.kind == .toolUse, let id = entry.toolID else { continue }

            if id.hasPrefix("repl_") || id.hasPrefix("repl-error"), let current {
                scripts.insert(current)
            } else if entry.name == "REPL" {
                current = id
            }
        }
        return scripts
    }

    public static func turns(from entries: [RemoteEntry]) -> [Self] {
        let hiddenScripts = scriptsWithInnerCalls(in: entries)
        let results = Dictionary(entries.filter { $0.kind == .toolResult }.compactMap { entry in entry.toolID.map { ($0, entry) } }) { _, last in last }
        var turns: [Self] = []
        for entry in entries {
            if entry.kind == .toolResult, entry.name == "bash-output" {
                guard let last = turns.indices.last, var prompt = turns[last].prompt, prompt.name == "bash" else { continue }

                prompt.shellOutput = entry.text.isEmpty ? nil : entry.text
                prompt.shellError = entry.detail
                turns[last].prompt = prompt
                continue
            }

            let isInterruption = entry.kind == .prompt && entry.name != "bash" && entry.text.hasPrefix("[Request interrupted by user")
            if entry.kind == .prompt, !isInterruption {
                turns.append(Self(id: entry.id, prompt: entry, end: entry.date))
                continue
            }

            if turns.isEmpty { turns.append(Self(id: entry.id, prompt: nil)) }
            let last = turns.count - 1
            turns[last].end = entry.date ?? turns[last].end
            turns[last].isInterrupted = turns[last].isInterrupted || isInterruption
            if entry.kind == .reply { turns[last].parts.append(.reply(entry)) }
            guard entry.kind == .toolUse, entry.name != "Poll", entry.toolID.map({ !hiddenScripts.contains($0) }) != false else { continue }

            let call = ToolCall(use: entry, result: entry.toolID.flatMap { results[$0] })
            switch turns[last].parts.last {
            case let .work(calls)? where !call.isCard:
                turns[last].parts[turns[last].parts.count - 1] = .work(calls + [call])
            case let .cards(calls)? where call.isCard:
                turns[last].parts[turns[last].parts.count - 1] = .cards(calls + [call])
            default:
                turns[last].parts.append(call.isCard ? .cards([call]) : .work([call]))
            }
        }
        return turns
    }
}
