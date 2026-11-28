import BerthCore
import Foundation
import Observation

@Observable
final class RemotePush {
    static let keyPathKey = "remotePushKeyPath"
    static let keyIDKey = "remotePushKeyID"
    static let teamIDKey = "remotePushTeamID"
    static let devicesKey = "remotePushDevices"
    private static let logsInsteadOfSending = Snapshot.output != nil

    struct Device: Codable, Equatable {
        let token: String
        let isSandbox: Bool
    }

    private struct Activity {
        let device: Device
        let registeredAt: Date
        var last: LiveActivityState.Status
        var hasBeenActive = false
    }

    private(set) var devices: [Device]
    @ObservationIgnored private var activities: [String: Activity] = [:]
    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var cachedJWT: (value: String, identity: String, issuedAt: Date)?

    init(store: Store) {
        self.store = store
        devices = UserDefaults.standard.data(forKey: Self.devicesKey).flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
    }

    var isConfigured: Bool {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: Self.keyPathKey) ?? ""
        return FileManager.default.isReadableFile(atPath: path)
            && !(defaults.string(forKey: Self.keyIDKey) ?? "").isEmpty
            && !(defaults.string(forKey: Self.teamIDKey) ?? "").isEmpty
    }

    func register(token: String, isSandbox: Bool) {
        guard APNs.isValidDeviceToken(token) else { return }

        let device = Device(token: token.lowercased(), isSandbox: isSandbox)
        guard devices.last != device else { return }

        devices = Array((devices.filter { $0.token != device.token } + [device]).suffix(APNs.maxDevices))
        save()
    }

    func registerActivity(sessionID: String, token: String, isSandbox: Bool) {
        guard APNs.isValidDeviceToken(token) else { return }

        let device = Device(token: token.lowercased(), isSandbox: isSandbox)
        let previous = activities[sessionID]
        activities[sessionID] = Activity(device: device, registeredAt: previous?.registeredAt ?? .now, last: previous?.last ?? .working, hasBeenActive: previous?.hasBeenActive ?? false)
        syncActivities()
    }

    func endActivity(sessionID: String) {
        activities[sessionID] = nil
    }

    func syncActivities() {
        guard !activities.isEmpty else { return }

        for (sessionID, activity) in activities {
            let live = store.liveBySession[sessionID]
            let current = LiveActivityState(sessionStatus: live?.status, statusUpdatedAt: live?.statusUpdatedAt, turnStart: store.turnStarts[sessionID], now: .now)
            let step = LiveActivityStep.next(current: current, last: activity.last, hasBeenActive: activity.hasBeenActive, age: Date.now.timeIntervalSince(activity.registeredAt))
            if current != nil { activities[sessionID]?.hasBeenActive = true }
            switch step {
            case .keep: continue

            case let .update(state):
                activities[sessionID]?.last = state.status
                sendActivity(.update, state, sessionID: sessionID, to: activity.device)

            case .end:
                activities[sessionID] = nil
                sendActivity(.end, LiveActivityState(status: .finished, since: Date.now.timeIntervalSince1970), sessionID: sessionID, to: activity.device)
            }
        }
    }

    func notify(_ alert: PushAlert, sessionID: String, title: String) {
        if Self.logsInsteadOfSending { print("would push \(sessionID): \(title) | \(alert.body)") }
        guard !Self.logsInsteadOfSending, isConfigured, !devices.isEmpty else { return }

        Task { _ = await deliver(alert, sessionID: sessionID, title: title) }
    }

    func sendTest() async -> String {
        guard isConfigured else { return "Choose the key file and enter the Key ID and Team ID first." }
        guard !devices.isEmpty else { return "No phone has registered yet. Open Berth Remote and allow notifications." }

        let outcomes = await deliver(.test, sessionID: "test", title: "Berth")
        let delivered = outcomes.count(where: { $0 == .delivered })
        let failure = outcomes.compactMap { outcome -> String? in
            guard case let .rejected(reason) = outcome else { return nil }

            return reason
        }.first
        if let failure { return "Apple rejected the notification (\(failure))." }

        return delivered == 0 ? "The phone is no longer registered. Open Berth Remote to register it again." : "Sent to \(delivered) \(delivered == 1 ? "phone" : "phones")."
    }

    private func deliver(_ alert: PushAlert, sessionID: String, title: String) async -> [APNsOutcome] {
        guard let jwt = providerToken() else { return [.rejected("The key file can’t be read")] }

        var outcomes: [APNsOutcome] = []
        for device in devices {
            let outcome = await send(alert, sessionID: sessionID, title: title, jwt: jwt, to: device)
            if outcome == .unregistered { forget(device) }
            if case let .rejected(reason) = outcome, reason.hasSuffix("ProviderToken") { cachedJWT = nil }
            outcomes.append(outcome)
        }
        return outcomes
    }

    private func sendActivity(_ event: LiveActivityEvent, _ state: LiveActivityState, sessionID: String, to device: Device) {
        if Self.logsInsteadOfSending { print("would push live activity \(sessionID): \(event.rawValue) \(state.status.rawValue)") }
        guard !Self.logsInsteadOfSending, isConfigured, let jwt = providerToken() else { return }

        Task {
            guard let request = try? APNs.liveActivityRequest(deviceToken: device.token, isSandbox: device.isSandbox, jwt: jwt, event: event, state: state, now: .now),
                  let (data, response) = try? await URLSession.shared.data(for: request)
            else { return }

            let outcome = APNs.outcome(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
            if outcome == .unregistered { activities[sessionID] = nil }
            if case let .rejected(reason) = outcome, reason.hasSuffix("ProviderToken") { cachedJWT = nil }
        }
    }

    private func send(_ alert: PushAlert, sessionID: String, title: String, jwt: String, to device: Device) async -> APNsOutcome {
        do {
            let request = try APNs.request(deviceToken: device.token, isSandbox: device.isSandbox, jwt: jwt, sessionID: sessionID, title: title, alert: alert)
            let (data, response) = try await URLSession.shared.data(for: request)
            return APNs.outcome(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            return .rejected(error.localizedDescription)
        }
    }

    private func providerToken() -> String? {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: Self.keyPathKey) ?? ""
        let keyID = defaults.string(forKey: Self.keyIDKey) ?? ""
        let teamID = defaults.string(forKey: Self.teamIDKey) ?? ""
        let identity = [path, keyID, teamID].joined(separator: "|")
        if let cachedJWT, cachedJWT.identity == identity, Date.now.timeIntervalSince(cachedJWT.issuedAt) < APNs.jwtLifetime { return cachedJWT.value }

        guard let pem = try? String(contentsOfFile: path, encoding: .utf8),
              let value = try? APNs.jwt(keyID: keyID, teamID: teamID, privateKeyPEM: pem, issuedAt: .now)
        else { return nil }

        cachedJWT = (value, identity, .now)
        return value
    }

    private func forget(_ device: Device) {
        devices.removeAll { $0 == device }
        save()
    }

    private func save() {
        guard store.persistsTabs, let data = try? JSONEncoder().encode(devices) else { return }

        UserDefaults.standard.set(data, forKey: Self.devicesKey)
    }
}
