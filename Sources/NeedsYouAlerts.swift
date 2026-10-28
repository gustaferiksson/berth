import AppKit
import BerthCore
import UserNotifications

enum NeedsYouAlerts {
    static let notifiesKey = "notifiesWhenSessionNeedsYou"
    private static let logsInsteadOfPosting = Snapshot.output != nil
    private static var authorization: Task<Bool, Never>?

    static func update(entered: [LiveSession], waitingCount: Int, store: Store) {
        let badge = waitingCount == 0 ? nil : "\(waitingCount)"
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        if logsInsteadOfPosting { print("badge: \(NSApp.dockTile.badgeLabel ?? "nil")") }
        guard UserDefaults.standard.object(forKey: notifiesKey) == nil || UserDefaults.standard.bool(forKey: notifiesKey) else { return }
        let selectedSession = store.tabs.first { $0.id == store.selectedTabID }?.sessionID
        for session in entered where !(NSApp.isActive && session.sessionId == selectedSession) {
            let project = URL(filePath: session.cwd).lastPathComponent
            let content = UNMutableNotificationContent()
            content.title = (store.activeSessions + store.archivedSessions).first { $0.id == session.sessionId }?.title ?? project
            content.body = ([project] + [session.waitingFor.map { String($0.prefix(60)) }].compactMap(\.self)).joined(separator: " · ")
            content.userInfo = ["sessionID": session.sessionId]
            if logsInsteadOfPosting {
                print("would notify \(session.sessionId): \(content.title) | \(content.body)")
                continue
            }
            post(UNNotificationRequest(identifier: session.sessionId, content: content, trigger: nil))
        }
    }

    private static func post(_ request: UNNotificationRequest) {
        let authorization = authorization ?? Task { (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false }
        Self.authorization = authorization
        Task {
            guard await authorization.value else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let sessionID = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        await showSession(sessionID)
    }

    private func showSession(_ id: String) async {
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
        await store.waitForScan()
        store.activate(.session(id))
    }
}
