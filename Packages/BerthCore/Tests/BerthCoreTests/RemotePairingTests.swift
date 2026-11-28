import BerthCore
import Foundation
import Testing

struct RemotePairingTests {
    private let token = "q3Zx+8/Lw0aKp9TnV2mR5cYb7HdEoFgJ="

    @Test func payloadRoundTripsAddressAndToken() throws {
        let payload = try #require(RemotePairing.payload(address: "wss://mac.acme.example.invalid", token: token))
        let parsed = try #require(RemotePairing.parse(payload))

        #expect(parsed.url.absoluteString == "wss://mac.acme.example.invalid")
        #expect(parsed.token == token)
    }

    @Test func payloadRefusesAnythingButWssAndAWellFormedToken() {
        #expect(RemotePairing.payload(address: "ws://mac.acme.example.invalid", token: token) == nil)
        #expect(RemotePairing.payload(address: "mac.acme.example.invalid", token: token) == nil)
        #expect(RemotePairing.payload(address: "wss://mac.acme.example.invalid", token: "short") == nil)
    }

    @Test func parseRejectsForeignOrMalformedPayloads() {
        let good = "berthremote://pair?url=wss%3A%2F%2Fmac.acme.example.invalid&token=q3Zx%2B8%2FLw0aKp9TnV2mR5cYb7HdEoFgJ%3D"
        #expect(RemotePairing.parse(good) != nil)

        let bad = [
            "https://pair?url=wss%3A%2F%2Fmac.acme.example.invalid&token=q3Zx8Lw0aKp9TnV2mR5cYb7H",
            "berthremote://other?url=wss%3A%2F%2Fmac.acme.example.invalid&token=q3Zx8Lw0aKp9TnV2mR5cYb7H",
            "berthremote://pair?url=ws%3A%2F%2Fmac.acme.example.invalid&token=q3Zx8Lw0aKp9TnV2mR5cYb7H",
            "berthremote://pair?url=http%3A%2F%2Fmac.acme.example.invalid&token=q3Zx8Lw0aKp9TnV2mR5cYb7H",
            "berthremote://pair?url=wss%3A%2F%2Fuser%3Apw%40mac.acme.example.invalid&token=q3Zx8Lw0aKp9TnV2mR5cYb7H",
            "berthremote://pair?url=wss%3A%2F%2Fmac.acme.example.invalid&token=short",
            "berthremote://pair?url=wss%3A%2F%2Fmac.acme.example.invalid&token=q3Zx8Lw0aKp9TnV2mR5cYb7H%20%0A",
            "berthremote://pair?url=wss%3A%2F%2Fmac.acme.example.invalid&token=q3Zx8Lw0aKp9TnV2mR5cYb7H&extra=1",
            "berthremote://pair?token=q3Zx8Lw0aKp9TnV2mR5cYb7H",
            "berthremote://pair?url=wss%3A%2F%2F&token=q3Zx8Lw0aKp9TnV2mR5cYb7H",
            "",
        ]
        for payload in bad {
            #expect(RemotePairing.parse(payload) == nil, "\(payload)")
        }
    }
}
