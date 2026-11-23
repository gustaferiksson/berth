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
        let agent = RemoteAgent(name: "Codex", asset: "HarnessCodex", canChangeSettings: false, canAttach: false)
        let session = RemoteSession(id: "invented-session", title: "Sort the seeds", folder: "/garden", branch: nil, lastActivity: Date(timeIntervalSinceReferenceDate: 0), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false, agent: agent)
        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RemoteSession.self, from: encoded)

        #expect(String(decoding: encoded, as: UTF8.self).contains(#""glyph":"HarnessCodex""#))
        #expect(decoded == session)
    }

    @Test func legacyAgentDecodesWithSymbolName() throws {
        let json = Data(#"{"name":"Claude","glyph":"sparkle","canChangeSettings":true,"canAttach":true}"#.utf8)
        let agent = try JSONDecoder().decode(RemoteAgent.self, from: json)

        #expect(agent.asset == "sparkle")
    }
}
