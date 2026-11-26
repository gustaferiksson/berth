import Foundation

public enum SubagentStopKey: Sendable, Equatable {
    case command(String)
    case enter, down, stop, escape
}

public enum SubagentStop {
    public static let verifiedVersion = "2.1.332"
    static let supportedSeries = "2.1"

    public static func isSupported(version: String?) -> Bool {
        guard let version else { return false }

        return version.split(separator: ".").prefix(2).joined(separator: ".") == supportedSeries
    }

    // /tasks lists shells, then monitors, then background agents, each in start order. One running task opens its detail view and x stops it; two or more open the list, where x stops the focused row and Esc closes.
    public static func keys(stopping target: SessionBackgroundTask, among tasks: [SessionBackgroundTask]) -> [SubagentStopKey]? {
        guard target.kind == .agent, !target.runsInForeground, target.status == .running else { return nil }

        let listed = tasks.filter { $0.status == .running && !$0.runsInForeground && $0.kind != .terminal }
        let order: [SessionBackgroundTask.Kind] = [.shell, .monitor, .agent]
        let rows = order.flatMap { kind in listed.filter { $0.kind == kind }.sorted { ($0.started, $0.id) < ($1.started, $1.id) } }
        guard let index = rows.firstIndex(where: { $0.id == target.id }) else { return nil }

        let opening: [SubagentStopKey] = [.command("/tasks"), .enter]
        let stopping = Array(repeating: SubagentStopKey.down, count: index) + [.stop]
        return opening + stopping + (rows.count > 1 ? [.escape] : [])
    }
}
