import SwiftUI

@main
struct BerthRemoteApp: App {
    @State private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            ZStack {
                if client.state == .connected {
                    SessionListView()
                } else {
                    ConnectView()
                }
            }
            .environment(client)
            .task {
                guard let url = UserDefaults.standard.string(forKey: "remoteURL").flatMap(URL.init(string:)), let token = UserDefaults.standard.string(forKey: "remoteToken"), !token.isEmpty else { return }
                client.connect(to: url, token: token)
            }
        }
    }
}
