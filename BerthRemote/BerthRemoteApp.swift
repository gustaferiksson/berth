import SwiftUI

@main
struct BerthRemoteApp: App {
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
            .environment(client)
            .environment(updates)
            .preferredColorScheme(colorScheme == "light" ? .light : colorScheme == "dark" ? .dark : nil)
            .task(id: scenePhase) {
                #if DEBUG
                if RemoteClient.isDemo {
                    if scenePhase == .active, client.state != .connected { client.seedDemo() }
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
