import UIKit
import UserNotifications

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemoteClient.shared.pushToken = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let sessionID = userInfo["sessionID"] as? String
        let status = userInfo["status"] as? String
        await MainActor.run { Self.open(sessionID: sessionID, status: status) }
    }

    static func open(sessionID: String?, status: String?) {
        guard let sessionID, status != "test" else { return }

        RemoteClient.shared.openedSessionID = sessionID
    }
}

#if DEBUG
func runSnapshotPushTap() async {
    guard let file = UserDefaults.standard.string(forKey: "snapshotPushPayload"),
          let payload = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: file))) as? [String: Any],
          let sessionID = payload["sessionID"] as? String
    else { return }

    PushDelegate.open(sessionID: sessionID, status: payload["status"] as? String)
    print("snapshotPushPayload opened \(sessionID)")
}
#endif
