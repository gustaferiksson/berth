import BerthCore
import CryptoKit
import Foundation
import Testing

struct APNsTests {
    private let token = String(repeating: "ab", count: 32)

    @Test func jwtIsAnEs256TokenTheKeyVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let jwt = try APNs.jwt(keyID: "KEY1234567", teamID: "TEAM123456", privateKeyPEM: key.pemRepresentation, issuedAt: issuedAt)
        let parts = jwt.split(separator: ".").map(String.init)

        #expect(parts.count == 3)
        #expect(!jwt.contains("=") && !jwt.contains("+") && !jwt.contains("/"))

        let header = try #require(JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: String])
        let claims = try #require(JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any])

        #expect(header == ["alg": "ES256", "kid": "KEY1234567"])
        #expect(claims["iss"] as? String == "TEAM123456")
        #expect(claims["iat"] as? Int == 1_700_000_000)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))

        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func requestTargetsTheEnvironmentAndCarriesOnlyTitleStatusAndSession() throws {
        let production = try APNs.request(deviceToken: token, isSandbox: false, jwt: "jwt", sessionID: "s1", title: "Repair the import checks", alert: .needsYou)
        let sandbox = try APNs.request(deviceToken: token, isSandbox: true, jwt: "jwt", sessionID: "s1", title: "Repair", alert: .finished)

        #expect(production.url?.absoluteString == "https://api.push.apple.com/3/device/\(token)")
        #expect(sandbox.url?.host() == "api.sandbox.push.apple.com")
        #expect(production.httpMethod == "POST")
        #expect(production.value(forHTTPHeaderField: "authorization") == "bearer jwt")
        #expect(production.value(forHTTPHeaderField: "apns-topic") == "dev.gustaf.berth.remote")
        #expect(production.value(forHTTPHeaderField: "apns-push-type") == "alert")

        let bodyData = try #require(production.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let aps = try #require(body["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: String])

        #expect(Set(body.keys) == ["aps", "sessionID", "status"])
        #expect(body["sessionID"] as? String == "s1")
        #expect(body["status"] as? String == "waiting")
        #expect(alert == ["title": "Repair the import checks", "body": "Needs you"])
    }

    @Test func requestRefusesATokenThatCouldEscapeThePath() {
        for bad in ["../x", "zz", String(repeating: "a", count: 31), token + "/", ""] {
            #expect(throws: URLError.self) { try APNs.request(deviceToken: bad, isSandbox: false, jwt: "j", sessionID: "s", title: "t", alert: .finished) }
        }
    }

    @Test func outcomesTellWhenToForgetADevice() {
        #expect(APNs.outcome(statusCode: 200, body: Data()) == .delivered)
        #expect(APNs.outcome(statusCode: 410, body: Data(#"{"reason":"Unregistered"}"#.utf8)) == .unregistered)
        #expect(APNs.outcome(statusCode: 400, body: Data(#"{"reason":"BadDeviceToken"}"#.utf8)) == .unregistered)
        #expect(APNs.outcome(statusCode: 403, body: Data(#"{"reason":"ExpiredProviderToken"}"#.utf8)) == .rejected("ExpiredProviderToken"))
    }

    @Test func pushTokenMessageRoundTrips() throws {
        let data = try JSONEncoder().encode(RemoteClientMessage.pushToken(token: token, isSandbox: true))
        guard case let .pushToken(decoded, isSandbox) = try JSONDecoder().decode(RemoteClientMessage.self, from: data) else { throw CancellationError() }

        #expect(decoded == token)
        #expect(isSandbox)
    }

    @Test func finishedTurnsNeedAPreviousBusyReadingAndNoWaiting() {
        let live = [
            LiveSession(pid: 1, sessionId: "done", cwd: "/a", status: "idle"),
            LiveSession(pid: 2, sessionId: "asks", cwd: "/a", status: "waiting"),
            LiveSession(pid: 3, sessionId: "still", cwd: "/a", status: "busy"),
            LiveSession(pid: 4, sessionId: "outside", cwd: "/a", status: "idle"),
        ]
        let inBerth: Set = ["done", "asks", "still", "gone"]

        #expect(NeedsYou.finished(previousBusy: nil, live: live, inBerth: inBerth).finished.isEmpty)

        let result = NeedsYou.finished(previousBusy: ["done", "asks", "still", "gone", "outside"], live: live, inBerth: inBerth)

        #expect(result.finished.map(\.sessionId) == ["done"])
        #expect(result.busy == ["still"])
    }

    private func decode(_ value: String) throws -> Data {
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        return try #require(Data(base64Encoded: padded))
    }
}
