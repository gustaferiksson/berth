import BerthCore
import Foundation
import Testing

struct RemoteTriageTests {
    @Test func triageActionsRoundTrip() throws {
        let actions: [RemoteSessionAction] = [.flag, .unflag, .unarchive, .snoozeOneHour, .snoozeTomorrow, .snoozeUntilNeedsYou, .unsnooze]

        for action in actions {
            let data = try JSONEncoder().encode(RemoteClientMessage.session(sessionID: "s", action: action))
            guard case let .session(sessionID, decoded) = try JSONDecoder().decode(RemoteClientMessage.self, from: data) else { throw CancellationError() }

            #expect(sessionID == "s")
            #expect(decoded == action)
        }
    }

    @Test func flaggedSessionsRoundTripAndOlderPayloadsDecode() throws {
        let session = RemoteSession(id: "s", title: "Fix", folder: "/acme", branch: nil, lastActivity: Date(timeIntervalSince1970: 0), status: nil, waitingFor: nil, waitingSince: nil, isOpen: false, isLocked: false, isFlagged: true)
        let decoded = try JSONDecoder().decode(RemoteSession.self, from: JSONEncoder().encode(session))

        #expect(decoded.isFlagged == true)

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json["isFlagged"] = nil
        let older = try JSONDecoder().decode(RemoteSession.self, from: JSONSerialization.data(withJSONObject: json))

        #expect(older.isFlagged == nil)
    }
}
