import SwiftUI

#if DEBUG
private struct RegularWidthSnapshot: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.environment(\.horizontalSizeClass, UserDefaults.standard.bool(forKey: "snapshotRegularWidth") ? .regular : sizeClass)
    }
}
#endif

@main
struct BerthRemoteApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) var pushDelegate
    @State private var client = RemoteClient.shared
    @State private var updates = UpdateCheck()
    @AppStorage("colorScheme") private var colorScheme = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if client.state == .connected || client.state == .reconnecting {
                    SessionListView()
                } else {
                    ConnectView()
                }
            }
            .safeAreaInset(edge: .top) {
                if client.state == .reconnecting {
                    ConnectionStatus()
                }
            }
            .onContinueUserActivity(SessionHandoff.activityType) { client.continueHandoff($0) }
            .environment(client)
            .environment(updates)
            #if DEBUG
            .modifier(RegularWidthSnapshot())
            .modifier(WidgetsSnapshot())
            #endif
            .preferredColorScheme(colorScheme == "light" ? .light : colorScheme == "dark" ? .dark : nil)
            .task(id: scenePhase) {
                #if DEBUG
                if RemoteClient.isDemo {
                    if scenePhase == .active, client.state != .connected { client.seedDemo() }
                    if scenePhase == .active { await runSnapshotPushTap() }
                    return
                }
                #endif
                if scenePhase == .background { return client.suspend() }
                guard scenePhase == .active else { return }

                client.resume()
                #if DEBUG
                await runSnapshotIntent()
                #endif
                await updates.checkIfDue()
            }
        }
        .commands { RemoteCommands() }
    }
}
