import Foundation

public enum SessionArchive {
    public static func split(_ sessions: [SessionSummary], archivedAt: [String: Date]) -> (active: [SessionSummary], archived: [SessionSummary], kept: [String: Date]) {
        let archived = sessions.filter { session in archivedAt[session.id].map { session.lastActivity <= $0 } ?? false }
        let archivedIDs = Set(archived.map(\.id))
        return (
            sessions.filter { !archivedIDs.contains($0.id) },
            archived.sorted { $0.lastPrompt > $1.lastPrompt },
            archivedAt.filter { archivedIDs.contains($0.key) }
        )
    }
}
