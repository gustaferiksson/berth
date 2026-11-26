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

    // /tasks lists shells, then monitors, then background agents, each newest first. The list opens on its first row, and when it is the only row the dialog opens that task's detail view instead; x stops either, and Esc closes whichever is open.
    public static func keys(stopping target: SessionBackgroundTask, among tasks: [SessionBackgroundTask]) -> [SubagentStopKey]? {
        guard target.kind == .agent, !target.runsInForeground, target.status == .running else { return nil }

        let listed = tasks.filter { $0.status == .running && !$0.runsInForeground && $0.kind != .terminal }
        let order: [SessionBackgroundTask.Kind] = [.shell, .monitor, .agent]
        let rows = order.flatMap { kind in listed.filter { $0.kind == kind }.sorted { ($0.started, $0.id) > ($1.started, $1.id) } }
        guard let index = rows.firstIndex(where: { $0.id == target.id }) else { return nil }

        return [.command("/tasks"), .enter] + Array(repeating: .down, count: index) + [.stop, .escape]
    }
}
