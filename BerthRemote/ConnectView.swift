import SwiftUI

struct ConnectView: View {
    @Environment(RemoteClient.self) private var client
    @AppStorage("remoteURL") private var address = ""
    @AppStorage("remoteToken") private var token = ""

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
                    Text("Turn on Remote in Berth’s General settings and expose it with tailscale serve.")
                }
                Section {
                    Button(client.state == .connecting ? "Connecting…" : "Connect", action: connect)
                        .disabled(URL(string: address)?.scheme == nil || token.isEmpty || client.state == .connecting)
                }
                if case let .disconnected(error?) = client.state {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Berth Remote")
        }
    }

    private func connect() {
        guard let url = URL(string: address) else { return }
        client.connect(to: url, token: token)
    }
}
