import Foundation

public enum IdleTabs {
    public static func unloadable<ID: Hashable>(_ tabs: [(id: ID, sessionID: String, touched: Date)], live: [String: LiveSession], lastActivity: [String: Date], pinned: Set<String>, selected: ID?, now: Date, threshold: TimeInterval) -> [ID] {
        guard threshold > 0 else { return [] }

        return tabs.filter { tab in
            guard tab.id != selected, !pinned.contains(tab.sessionID),
                  let session = live[tab.sessionID], session.status == "idle", session.attachID == nil
            else { return false }

            let statusUpdatedAt = session.statusUpdatedAt ?? 0
            let isResumeStatus = session.startedAt.map { statusUpdatedAt - $0 <= 30_000 } ?? false
            let statusChanged = isResumeStatus ? Date.distantPast : Date(timeIntervalSince1970: statusUpdatedAt / 1000)
            let touched = max(tab.touched, lastActivity[tab.sessionID] ?? .distantPast, statusChanged)
            return now.timeIntervalSince(touched) > threshold
        }.map(\.id)
    }
}
