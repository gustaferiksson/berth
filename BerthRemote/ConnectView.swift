import SwiftUI

struct ConnectView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(UpdateCheck.self) private var updates
    @AppStorage("remoteURL") private var address = ""
    @State private var token = ""
    @State private var isScanning = false
    @State private var pairingError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("wss://mac.tailnet.ts.net", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .monospaced()
                    SecureField("Token", text: $token)
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") { isScanning = true }
                } footer: {
                    Text("Turn on Remote in Berth’s General settings, expose it with tailscale serve and enter its wss:// address.")
                }
                Section {
                    Button(client.state == .connecting ? "Connecting…" : "Connect", action: connect)
                        .disabled(RemoteClient.url(from: address) == nil || token.isEmpty || client.state == .connecting)
                }
                if let pairingError {
                    Section {
                        Text(pairingError)
                            .foregroundStyle(.red)
                    }
                }
                if case let .disconnected(error?) = client.state {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                if let version = updates.available {
                    Section {
                        Link(destination: UpdateCheck.installURL) {
                            Label("Install Berth Remote \(version)", systemImage: "arrow.down.circle")
                        }
                    }
                }
            }
            .navigationTitle("Berth Remote")
            .onAppear { token = RemoteClient.savedToken ?? "" }
            .sheet(isPresented: $isScanning) { PairingScanner(onScan: { pair(payload: $0) }) }
            #if DEBUG
            .task {
                guard let payload = UserDefaults.standard.string(forKey: "snapshotPairPayload") else { return }

                pair(payload: payload)
            }
            #endif
        }
    }

    private func pair(payload: String) {
        guard let pairing = RemotePairing.parse(payload), let url = RemoteClient.url(from: pairing.url.absoluteString) else {
            pairingError = "That isn’t a Berth Remote pairing code."
            return
        }

        pairingError = nil
        address = url.absoluteString
        token = pairing.token
        client.connect(to: url, token: pairing.token)
    }

    private func connect() {
        guard let url = RemoteClient.url(from: address) else { return }

        client.connect(to: url, token: token)
    }
}
