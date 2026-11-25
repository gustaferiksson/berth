import BerthCore
import Foundation
import Testing

struct RemoteSectionsTests {
    @Test func sectionWithDisplayFieldsRoundTrips() throws {
        let session = RemoteSession(id: "demo", title: "Sort the seeds", folder: "/garden", branch: nil, lastActivity: Date(timeIntervalSinceReferenceDate: 0), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false, isPinned: true)
        let group = RemoteGroup(id: "recent:older", title: "Older", sessions: [session], isCollapsed: true, visibleCount: 0)

        let encoded = try JSONEncoder().encode([group])
        let decoded = try JSONDecoder().decode([RemoteGroup].self, from: encoded)

        #expect(decoded == [group])
    }

    @Test func legacySectionDecodesWithoutDisplayFields() throws {
        let json = Data("""
        {
          "id": "pinned",
          "title": "Pinned",
          "sessions": [
            {"id":"demo","title":"Sort the seeds","folder":"/garden","lastActivity":0,"isOpen":false,"isLocked":false}
          ]
        }
        """.utf8)
        let group = try JSONDecoder().decode(RemoteGroup.self, from: json)
        let session = try #require(group.sessions.first)

        #expect(group.isCollapsed == nil)
        #expect(group.visibleCount == nil)
        #expect(session.isPinned == nil)
    }
}
