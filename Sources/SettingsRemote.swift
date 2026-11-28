import SwiftUI
import UniformTypeIdentifiers

struct RemoteSettings: View {
    @AppStorage(RemoteServer.enabledKey) private var isRemoteEnabled = false
    @AppStorage(RemoteServer.tokenKey) private var remoteToken = ""
    @AppStorage(RemotePush.keyPathKey) private var pushKeyPath = ""
    @AppStorage(RemotePush.keyIDKey) private var pushKeyID = ""
    @AppStorage(RemotePush.teamIDKey) private var pushTeamID = ""
    @State private var isTokenShown = false
    @State private var isChoosingPushKey = false
    @State private var pushTestResult: String?
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
            if isRemoteEnabled {
                Section {
                    LabeledContent("Key File") {
                        Text(pushKeyPath.isEmpty ? "None" : URL(filePath: pushKeyPath).lastPathComponent)
                            .foregroundStyle(.secondary)
                        Button("Choose") { isChoosingPushKey = true }
                    }
                    TextField("Key ID", text: $pushKeyID)
                    TextField("Team ID", text: $pushTeamID)
                    HStack {
                        Button("Send Test Notification") {
                            Task { pushTestResult = await store.remote.push.sendTest() }
                        }
                        if let pushTestResult {
                            Text(pushTestResult)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Push Notifications")
                } footer: {
                    Text("Needs an APNs auth key (.p8) from the Apple developer portal. The key stays on this Mac, only its location is stored. \(store.remote.push.devices.count) registered \(store.remote.push.devices.count == 1 ? "phone" : "phones"). Notifications carry the session title and status, never transcript text.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: isRemoteEnabled ? 600 : 280)
        .fileImporter(isPresented: $isChoosingPushKey, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { pushKeyPath = url.path }
        }
        .onChange(of: isRemoteEnabled) {
            if remoteToken.isEmpty { remoteToken = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
            store.remote.update()
        }
        .onChange(of: remoteToken) { store.remote.update() }
    }
}
