import SwiftUI

struct RemoteSettings: View {
    @AppStorage(RemoteServer.enabledKey) private var isRemoteEnabled = false
    @AppStorage(RemoteServer.tokenKey) private var remoteToken = ""
    @State private var isTokenShown = false
    @Environment(Store.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle("Allow remote control", isOn: $isRemoteEnabled)
                if isRemoteEnabled {
                    LabeledContent("Token") {
                        Text(isTokenShown ? remoteToken : String(repeating: "•", count: 16))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Button(isTokenShown ? "Hide Token" : "Show Token", systemImage: isTokenShown ? "eye.slash" : "eye") { isTokenShown.toggle() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    Button("Regenerate Token") { remoteToken = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
                    if let failure = store.remote.failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Remote Control")
            } footer: {
                Text("Experimental. Listens on 127.0.0.1:\(String(RemoteServer.port)) only. To reach it from your phone, run `tailscale serve --bg \(String(RemoteServer.port))` and connect Berth Remote to wss://<this Mac>.<tailnet>.ts.net with the token. Regenerating the token disconnects every phone.")
            }
        }
        .formStyle(.grouped)
        .frame(height: isRemoteEnabled ? 420 : 280)
        .onChange(of: isRemoteEnabled) {
            if remoteToken.isEmpty { remoteToken = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
            store.remote.update()
        }
        .onChange(of: remoteToken) { store.remote.update() }
    }
}
