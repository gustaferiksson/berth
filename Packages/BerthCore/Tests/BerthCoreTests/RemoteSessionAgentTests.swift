import BerthCore
import Foundation
import Testing

struct RemoteSessionAgentTests {
    @Test func legacySessionDecodesWithoutAgent() throws {
        let json = Data(#"{"id":"invented-session","title":"Sort the seeds","folder":"/garden","lastActivity":0,"isOpen":false,"isLocked":false}"#.utf8)
        let session = try JSONDecoder().decode(RemoteSession.self, from: json)

        #expect(session.agent == nil)
    }

    @Test func sessionWithAgentRoundTrips() throws {
        let agent = RemoteAgent(name: "Codex", glyph: "terminal", canChangeSettings: false, canAttach: false)
        let session = RemoteSession(id: "invented-session", title: "Sort the seeds", folder: "/garden", branch: nil, lastActivity: Date(timeIntervalSinceReferenceDate: 0), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false, agent: agent)
        let decoded = try JSONDecoder().decode(RemoteSession.self, from: JSONEncoder().encode(session))

        #expect(decoded == session)
    }
}
