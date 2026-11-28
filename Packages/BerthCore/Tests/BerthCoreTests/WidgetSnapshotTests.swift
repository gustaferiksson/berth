import BerthCore
import Foundation
import Testing

struct WidgetSnapshotTests {
    private func session(_ id: String, _ title: String, status: String?) -> RemoteSession {
        RemoteSession(id: id, title: title, folder: "/Projects/acme", branch: nil, lastActivity: .now, status: status, waitingFor: nil, waitingSince: nil, isOpen: true, isLocked: false)
    }

    @Test func snapshotKeepsOnlyWaitingSessionsOnceEach() {
        let pinned = session("a", "Fix the import checks", status: "waiting")
        let groups = [
            RemoteGroup(id: "attention", title: "Needs Attention", sessions: [pinned, session("b", "Rebuild the index", status: "busy")]),
            RemoteGroup(id: "pinned", title: "Pinned", sessions: [pinned, session("c", "Trim the logs", status: "waiting"), session("d", "Idle one", status: "idle")]),
        ]

        #expect(WidgetSnapshot(groups: groups).needsYou == [.init(id: "a", title: "Fix the import checks"), .init(id: "c", title: "Trim the logs")])
    }

    @Test func pushesMoveSessionsInAndOutOfTheList() {
        let start = WidgetSnapshot(needsYou: [.init(id: "a", title: "First")])
        let added = start.applying(pushStatus: "waiting", sessionID: "b", title: "Second")
        let renamed = added.applying(pushStatus: "waiting", sessionID: "a", title: "First renamed")

        #expect(added.needsYou.map(\.id) == ["b", "a"])
        #expect(renamed.needsYou == [.init(id: "a", title: "First renamed"), .init(id: "b", title: "Second")])
        #expect(renamed.applying(pushStatus: "idle", sessionID: "a", title: "First renamed").needsYou.map(\.id) == ["b"])
        #expect(start.applying(pushStatus: "test", sessionID: "test", title: "Berth") == start)
    }

    @Test func snapshotRoundTripsAndIsCapped() throws {
        let many = (0..<30).map { WidgetSnapshot.Item(id: "s\($0)", title: "Session \($0)") }
        let snapshot = WidgetSnapshot(needsYou: many)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))

        #expect(decoded == snapshot)
        #expect(decoded.needsYou.count == WidgetSnapshot.maxItems)
    }
}
