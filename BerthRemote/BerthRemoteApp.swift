import SwiftUI

@main
struct BerthRemoteApp: App {
    @State private var client = RemoteClient()
    @State private var updates = UpdateCheck()
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
            .safeAreaInset(edge: .bottom) {
                if let version = updates.available {
                    Link(destination: UpdateCheck.installURL) {
                        Label("Install Berth Remote \(version)", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .safeAreaInset(edge: .top) {
                if client.state == .reconnecting {
                    Label {
                        Text("Reconnecting…")
                    } icon: {
                        ProgressView()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .environment(client)
            .task(id: scenePhase) {
                if scenePhase == .background { return client.suspend() }
                guard scenePhase == .active else { return }
                client.resume()
                await updates.checkIfDue()
            }
        }
    }
}
