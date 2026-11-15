import SwiftUI

struct ConnectView: View {
    @Environment(RemoteClient.self) private var client
    @AppStorage("remoteURL") private var address = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("wss://mac.tailnet.ts.net", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token", text: $token)
                } footer: {
                    Text("Turn on Remote in Berth’s General settings, expose it with tailscale serve and enter its wss:// address.")
                }
                Section {
                    Button(client.state == .connecting ? "Connecting…" : "Connect", action: connect)
                        .disabled(RemoteClient.url(from: address) == nil || token.isEmpty || client.state == .connecting)
                }
                if case let .disconnected(error?) = client.state {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Berth Remote")
            .onAppear { token = RemoteClient.savedToken ?? "" }
        }
    }

    private func connect() {
        guard let url = RemoteClient.url(from: address) else { return }
        client.connect(to: url, token: token)
    }
}
