import AppKit
import BerthCore
import Foundation
import UserNotifications

enum AgentBrowserPolicy: String, CaseIterable {
    case ask
    case allow
    case off

    var title: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Always allow"
        case .off: "Off"
        }
    }
}

@Observable
final class BrowserAccess {
    enum Decision {
        case allowed
        case denied
    }

    struct Request: Identifiable {
        let id = UUID()
        let key: String
        let title: String
        let session: SessionSummary?
        let folder: String
        let url: String?
    }

    static let policyKey = "agentBrowserControl"
    static var promptTimeout = Duration.seconds(120)
    static let deniedMessage = "Browser access was denied for this session"
    static let offMessage = "Agent browser control is off in Berth’s Settings"
    static let unansweredMessage = "Browser access wasn’t approved in time. Run the command again once the user can answer the prompt in Berth"

    private(set) var decisions: [String: Decision] = [:]
    private(set) var requests: [Request] = []
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<Decision?, Never>]] = [:]

    var policy: AgentBrowserPolicy {
        AgentBrowserPolicy(rawValue: UserDefaults.standard.string(forKey: Self.policyKey) ?? "") ?? .ask
    }

    func authorize(key: String, title: String, session: SessionSummary?, folder: String, url: String?) async -> String? {
        if policy == .off { return Self.offMessage }

        if decisions[key] == .denied { return Self.deniedMessage }

        if policy == .allow || decisions[key] == .allowed { return nil }

        let decision = await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
            guard waiters[key]?.count == 1 else { return }

            let request = Request(key: key, title: title, session: session, folder: folder, url: url)
            requests.append(request)
            notifyIfInactive(request)
            Task {
                try? await Task.sleep(for: Self.promptTimeout)
                resolve(request, with: nil)
            }
        }
        switch decision {
        case .allowed: return nil
        case .denied: return Self.deniedMessage
        case nil: return Self.unansweredMessage
        }
    }

    func resolve(_ request: Request, with decision: Decision?) {
        guard let index = requests.firstIndex(where: { $0.id == request.id }) else { return }

        requests.remove(at: index)
        if let decision { decisions[request.key] = decision }
        for waiter in waiters.removeValue(forKey: request.key) ?? [] { waiter.resume(returning: decision) }
    }

    func decide(_ decision: Decision, for key: String) {
        decisions[key] = decision
    }

    private func notifyIfInactive(_ request: Request) {
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = "Browser access requested"
        content.body = "The agent in \(request.title) wants to use Berth’s browser."
        content.userInfo = ["sessionID": request.key]
        if Snapshot.output != nil { return print("would notify \(request.key): \(content.title) | \(content.body)") }

        NeedsYouAlerts.post(UNNotificationRequest(identifier: "browser-access-" + request.key, content: content, trigger: nil))
    }
}
