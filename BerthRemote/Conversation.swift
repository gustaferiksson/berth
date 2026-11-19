import Foundation

struct ToolCall: Identifiable {
    let use: RemoteEntry
    let result: RemoteEntry?

    var id: String { use.id }

    var kind: ToolKind { ToolKind(name: use.name ?? "") }

    var verb: (past: String, present: String) {
        switch use.name {
        case "Write": ("Wrote", "Writing")
        case "WebSearch": ("Searched the web for", "Searching the web for")
        case "WebFetch": ("Fetched", "Fetching")
        default: kind.verb
        }
    }

    var subject: String {
        if let command = use.command { return String(command.prefix { $0 != "\n" }) }
        if let path = use.filePath { return URL(filePath: path).lastPathComponent }
        if use.name == "WebFetch", let host = use.detail.flatMap(URL.init(string:))?.host() { return host }
        if kind == .other { return (use.name ?? "").components(separatedBy: "__").last ?? "" }
        return kind == .todo ? "" : use.detail ?? ""
    }

    static func summary(of calls: [Self]) -> String {
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

enum ToolKind {
    case command, read, edit, search, web, agent, todo, question, other

    init(name: String) {
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

    var icon: String {
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

    var verb: (past: String, present: String) {
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

    func phrase(for calls: [ToolCall]) -> String {
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

enum LiveCall: Equatable {
    case running(String)
    case waiting(String)

    var id: String {
        switch self {
        case let .running(id), let .waiting(id): id
        }
    }
}

enum TurnPart: Identifiable {
    case reply(RemoteEntry)
    case work([ToolCall])

    var id: String {
        switch self {
        case let .reply(entry): entry.id
        case let .work(calls): calls.first?.id ?? ""
        }
    }
}

struct Turn: Identifiable {
    let id: String
    let prompt: RemoteEntry?
    var parts: [TurnPart] = []
    var end: Date?
    var isInterrupted = false

    var openCall: ToolCall? {
        guard case let .work(calls) = parts.last, let call = calls.last, call.result == nil else { return nil }

        return call
    }

    var duration: Duration? {
        guard let start = prompt?.date, let end, end > start else { return nil }

        return .seconds(end.timeIntervalSince(start).rounded())
    }

    static func turns(from entries: [RemoteEntry]) -> [Self] {
        let results = Dictionary(entries.filter { $0.kind == .toolResult }.compactMap { entry in entry.toolID.map { ($0, entry) } }) { _, last in last }
        var turns: [Self] = []
        for entry in entries {
            let isInterruption = entry.kind == .prompt && entry.text.hasPrefix("[Request interrupted by user")
            if entry.kind == .prompt, !isInterruption {
                turns.append(Self(id: entry.id, prompt: entry, end: entry.date))
                continue
            }

            if turns.isEmpty { turns.append(Self(id: entry.id, prompt: nil)) }
            let last = turns.count - 1
            turns[last].end = entry.date ?? turns[last].end
            turns[last].isInterrupted = turns[last].isInterrupted || isInterruption
            if entry.kind == .reply { turns[last].parts.append(.reply(entry)) }
            guard entry.kind == .toolUse else { continue }

            let call = ToolCall(use: entry, result: entry.toolID.flatMap { results[$0] })
            if case let .work(calls) = turns[last].parts.last {
                turns[last].parts[turns[last].parts.count - 1] = .work(calls + [call])
            } else {
                turns[last].parts.append(.work([call]))
            }
        }
        return turns
    }
}
