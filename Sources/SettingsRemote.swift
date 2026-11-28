import BerthCore
import CoreImage.CIFilterBuiltins
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
    @AppStorage("remotePairAddress") private var pairAddress = ""
    @State private var isPairing = Self.startsPairing
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
                    Button("Pair iPhone", systemImage: "qrcode") { isPairing.toggle() }
                    Button("Regenerate Token") { remoteToken = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
                    if let failure = store.remote.failure {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
                if isRemoteEnabled, isPairing {
                    pairing
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
        .frame(height: isRemoteEnabled ? (isPairing ? 900 : 600) : 280)
        .fileImporter(isPresented: $isChoosingPushKey, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { pushKeyPath = url.path }
        }
        .onChange(of: isRemoteEnabled) {
            if remoteToken.isEmpty { remoteToken = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
            store.remote.update()
        }
        .onChange(of: remoteToken) {
            isPairing = false
            store.remote.update()
        }
        .onDisappear { isPairing = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in isPairing = false }
    }

    @ViewBuilder private var pairing: some View {
        TextField("Address", text: $pairAddress, prompt: Text("wss://mac.tailnet.ts.net"))
            .autocorrectionDisabled()
            .monospaced()
        if let payload = RemotePairing.payload(address: pairAddress, token: remoteToken), let code = Self.qrCode(payload) {
            Image(nsImage: code)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Pairing QR code")
            Text("Scan it with Berth Remote on your iPhone. Anyone who sees this code can control your sessions, so hide it when you are done.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Enter the wss:// address from tailscale serve to show the code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func qrCode(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }

        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private static var startsPairing: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "snapshotPairShown")
        #else
        false
        #endif
    }
}
