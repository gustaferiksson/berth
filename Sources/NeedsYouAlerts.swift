import AppKit
import BerthCore
import UserNotifications

enum NeedsYouAlerts {
    static let notifiesKey = "notifiesWhenSessionNeedsYou"
    private static let logsInsteadOfPosting = Snapshot.output != nil
    private static var authorization: Task<Bool, Never>?
    private static var busy: Set<String>?

    static func update(entered: [LiveSession], live: [LiveSession], needsYouCount: Int, store: Store) {
        let badge = needsYouCount == 0 ? nil : "\(needsYouCount)"
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        if logsInsteadOfPosting { print("badge: \(NSApp.dockTile.badgeLabel ?? "nil")") }
        store.remote.push.syncActivities()
        let turns = NeedsYou.finished(previousBusy: busy, live: live, inBerth: Set(store.tabs.compactMap(\.sessionID)))
        busy = turns.busy
        let selectedSession = store.tabs.first { $0.id == store.selectedTabID }?.sessionID
        let isUnattended = { (session: LiveSession) in !(NSApp.isActive && session.sessionId == selectedSession) }
        let pushes = entered.map { ($0, PushAlert.needsYou) } + turns.finished.map { ($0, PushAlert.finished) }
        for (session, alert) in pushes where isUnattended(session) {
            let summary = store.sessionsByID[session.sessionId]
            let title = summary?.title ?? URL(filePath: summary?.checkout ?? session.cwd).lastPathComponent
            store.remote.push.notify(alert, sessionID: session.sessionId, title: title)
        }
        guard UserDefaults.standard.object(forKey: notifiesKey) == nil || UserDefaults.standard.bool(forKey: notifiesKey) else { return }

        for session in entered where isUnattended(session) {
            let summary = store.sessionsByID[session.sessionId]
            let project = URL(filePath: summary?.checkout ?? session.cwd).lastPathComponent
            let content = UNMutableNotificationContent()
            content.title = summary?.title ?? project
            content.body = ([project] + [session.waitingFor.map { String($0.prefix(60)) }].compactMap(\.self)).joined(separator: " · ")
            content.userInfo = ["sessionID": session.sessionId]
            if logsInsteadOfPosting {
                print("would notify \(session.sessionId): \(content.title) | \(content.body)")
                continue
            }
            post(UNNotificationRequest(identifier: session.sessionId, content: content, trigger: nil))
        }
    }

    static func post(_ request: UNNotificationRequest) {
        let authorization = authorization ?? Task { await (try? UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false }
        Self.authorization = authorization
        Task {
            guard await authorization.value else { return }

            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
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
