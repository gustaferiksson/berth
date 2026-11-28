import BerthCore
import Foundation
import Testing

struct LiveActivityTests {
    private let token = String(repeating: "cd", count: 32)
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func stateReadsTheLiveStatusAndAnIdleSessionHasNone() {
        let turn = Date(timeIntervalSince1970: 1_699_999_700)

        #expect(LiveActivityState(sessionStatus: "busy", statusUpdatedAt: 1_699_999_900_000, turnStart: turn, now: now) == .init(status: .working, since: 1_699_999_700))
        #expect(LiveActivityState(sessionStatus: "busy", statusUpdatedAt: 1_699_999_900_000, turnStart: nil, now: now) == .init(status: .working, since: 1_699_999_900))
        #expect(LiveActivityState(sessionStatus: "waiting", statusUpdatedAt: 1_699_999_950_000, turnStart: turn, now: now) == .init(status: .waiting, since: 1_699_999_950))
        #expect(LiveActivityState(sessionStatus: "idle", statusUpdatedAt: nil, turnStart: nil, now: now) == nil)
        #expect(LiveActivityState(sessionStatus: nil, statusUpdatedAt: nil, turnStart: nil, now: now) == nil)
    }

    @Test func stepsFlipOnStatusChangeAndEndOnlyAfterTheSessionWasActiveOrTheGraceRanOut() {
        let working = LiveActivityState(status: .working, since: 1)
        let waiting = LiveActivityState(status: .waiting, since: 2)

        #expect(LiveActivityStep.next(current: working, last: .working, hasBeenActive: true, age: 100) == .keep)
        #expect(LiveActivityStep.next(current: waiting, last: .working, hasBeenActive: false, age: 1) == .update(waiting))
        #expect(LiveActivityStep.next(current: nil, last: .working, hasBeenActive: false, age: 5) == .keep)
        #expect(LiveActivityStep.next(current: nil, last: .working, hasBeenActive: false, age: 31) == .end)
        #expect(LiveActivityStep.next(current: nil, last: .waiting, hasBeenActive: true, age: 5) == .end)
    }

    @Test func updateRequestIsALiveActivityPushWithTheContentStateTheSystemDecodes() throws {
        let state = LiveActivityState(status: .waiting, since: 1_699_999_950.5)
        let request = try APNs.liveActivityRequest(deviceToken: token, isSandbox: true, jwt: "jwt", event: .update, state: state, now: now)

        #expect(request.url?.absoluteString == "https://api.sandbox.push.apple.com/3/device/\(token)")
        #expect(request.value(forHTTPHeaderField: "apns-push-type") == "liveactivity")
        #expect(request.value(forHTTPHeaderField: "apns-topic") == "dev.gustaf.berth.remote.push-type.liveactivity")

        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let aps = try #require(body["aps"] as? [String: Any])

        #expect(Set(body.keys) == ["aps"])
        #expect(aps["event"] as? String == "update")
        #expect(aps["timestamp"] as? Int == 1_700_000_000)
        #expect(aps["stale-date"] as? Int == 1_700_000_000 + LiveActivityState.staleAfter)
        #expect(aps["dismissal-date"] == nil)

        let rawState = try #require(aps["content-state"])
        let contentState = try JSONSerialization.data(withJSONObject: rawState)
        #expect(String(decoding: contentState, as: UTF8.self).contains("\"waiting\""))
        #expect(try JSONDecoder().decode(LiveActivityState.self, from: contentState) == state)
    }

    @Test func endRequestDismissesSoonAndCarriesNoStaleDate() throws {
        let request = try APNs.liveActivityRequest(deviceToken: token, isSandbox: false, jwt: "jwt", event: .end, state: .init(status: .finished, since: 1_700_000_000), now: now)
        let bodyData = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let aps = try #require(body["aps"] as? [String: Any])

        #expect(request.url?.host() == "api.push.apple.com")
        #expect(aps["event"] as? String == "end")
        #expect(aps["dismissal-date"] as? Int == 1_700_000_000 + LiveActivityState.dismissAfter)
        #expect(aps["stale-date"] == nil)
        #expect(throws: URLError.self) { try APNs.liveActivityRequest(deviceToken: "../x", isSandbox: false, jwt: "j", event: .end, state: .init(status: .finished, since: 0), now: now) }
    }

    @Test func tokenMessagesRoundTrip() throws {
        let register = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(RemoteClientMessage.liveActivityToken(sessionID: "s1", token: token, isSandbox: true)))
        let end = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(RemoteClientMessage.liveActivityEnded(sessionID: "s1")))

        guard case let .liveActivityToken(sessionID, decoded, isSandbox) = register, case let .liveActivityEnded(endedID) = end else { throw CancellationError() }

        #expect(sessionID == "s1" && decoded == token && isSandbox && endedID == "s1")
    }
}
