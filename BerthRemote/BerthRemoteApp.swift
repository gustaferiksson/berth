import SwiftUI

@main
struct BerthRemoteApp: App {
    @State private var client = RemoteClient()
    @State private var updates = UpdateCheck()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if client.state == .connected {
                    SessionListView()
                } else {
                    ConnectView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let version = updates.available {
                    Link(destination: UpdateCheck.installURL) {
                        Label("Install Berth Remote \(version)", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .environment(client)
            .task {
                guard let url = UserDefaults.standard.string(forKey: "remoteURL").flatMap(URL.init(string:)), let token = UserDefaults.standard.string(forKey: "remoteToken"), !token.isEmpty else { return }
                client.connect(to: url, token: token)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await updates.checkIfDue()
            }
        }
    }
}
