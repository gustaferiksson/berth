import CryptoKit
import Foundation

public enum PushAlert: String, Sendable {
    case needsYou
    case finished
    case test

    public var status: String {
        switch self {
        case .needsYou: "waiting"
        case .finished: "idle"
        case .test: "test"
        }
    }

    public var body: String {
        switch self {
        case .needsYou: "Needs you"
        case .finished: "Finished"
        case .test: "Test notification"
        }
    }
}

public enum APNsOutcome: Equatable, Sendable {
    case delivered
    case unregistered
    case rejected(String)
}

public enum APNs {
    public static let topic = "dev.gustaf.berth.remote"
    public static let maxDevices = 20
    public static let jwtLifetime: TimeInterval = 30 * 60

    public static func isValidDeviceToken(_ token: String) -> Bool {
        token.range(of: "^[0-9a-fA-F]{32,200}$", options: .regularExpression) != nil
    }

    public static func jwt(keyID: String, teamID: String, privateKeyPEM: String, issuedAt: Date) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID], options: .sortedKeys)
        let claims = try JSONSerialization.data(withJSONObject: ["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)], options: .sortedKeys)
        let signingInput = "\(base64URL(header)).\(base64URL(claims))"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    public static func request(deviceToken: String, isSandbox: Bool, jwt: String, sessionID: String, title: String, alert: PushAlert) throws -> URLRequest {
        guard isValidDeviceToken(deviceToken), let url = URL(string: "https://\(isSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com")/3/device/\(deviceToken)") else { throw URLError(.badURL) }

        let payload: [String: Any] = [
            "aps": ["alert": ["title": String(title.prefix(120)), "body": alert.body], "sound": "default", "thread-id": sessionID, "content-available": 1],
            "sessionID": sessionID,
            "status": alert.status,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue(sessionID, forHTTPHeaderField: "apns-collapse-id")
        return request
    }

    public static func outcome(statusCode: Int, body: Data) -> APNsOutcome {
        if statusCode == 200 { return .delivered }

        let reason = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["reason"] as? String ?? "HTTP \(statusCode)"
        if statusCode == 410 || reason == "BadDeviceToken" { return .unregistered }

        return .rejected(reason)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
