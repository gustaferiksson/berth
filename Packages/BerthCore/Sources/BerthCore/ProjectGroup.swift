import Foundation

public struct ProjectGroup: Sendable, Identifiable {
    public var id: String { cwd }
    public let cwd: String
    public let sessions: [SessionSummary]
    public let lastActivity: Date

    public init(cwd: String, sessions: [SessionSummary], lastActivity: Date) {
        self.cwd = cwd
        self.sessions = sessions
        self.lastActivity = lastActivity
    }

    public var name: String { URL(filePath: cwd).lastPathComponent }

    public static func grouped(_ sessions: [SessionSummary]) -> [ProjectGroup] {
        Dictionary(grouping: sessions, by: \.cwd)
            .map { cwd, sessions in
                let sorted = sessions.sorted { $0.lastActivity > $1.lastActivity }
                return ProjectGroup(cwd: cwd, sessions: sorted, lastActivity: sorted.first?.lastActivity ?? .distantPast)
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }
}
