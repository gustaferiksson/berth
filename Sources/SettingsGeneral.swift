import SwiftUI

struct GeneralSettings: View {
    static let unloadIdleKey = "unloadIdleSessionsAfter"
    static let reviewKey = "reviewEnabled"

    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage(NeedsYouAlerts.notifiesKey) private var notifiesWhenNeeded = true
    @AppStorage(unloadIdleKey) private var unloadIdleAfter = 14_400.0
    @AppStorage(reviewKey) private var isReviewEnabled = false
    @AppStorage(RemoteServer.enabledKey) private var isRemoteEnabled = false
    @AppStorage(RemoteServer.tokenKey) private var remoteToken = ""
    @Environment(Store.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle("Notify when a session needs you", isOn: $notifiesWhenNeeded)
            } header: {
                Text("Notifications")
            } footer: {
                Text("The Dock icon always shows how many sessions need you.")
            }
            Section {
                Picker("Unload idle sessions after", selection: $unloadIdleAfter) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(3_600.0)
                    Text("4 hours").tag(14_400.0)
                    Text("1 day").tag(86_400.0)
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("Unloaded sessions stay in the sidebar and resume when clicked. Pinned, working and waiting sessions stay loaded.")
            }
            Section {
                Picker("Position", selection: $sidebarPosition) {
                    Text("Left").tag(SidebarPosition.left)
                    Text("Right").tag(SidebarPosition.right)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Sidebar")
            }
            Section {
                Toggle("Review changes in Berth", isOn: $isReviewEnabled)
            } header: {
                Text("Review")
            } footer: {
                Text("Experimental. Adds Review Changes (⇧⌘R) to Claude sessions: a diff of the session’s branch and uncommitted work, with line comments sent back to Claude.")
            }
            Section {
                Toggle("Allow remote control", isOn: $isRemoteEnabled)
                if isRemoteEnabled {
                    LabeledContent("Token") {
                        Text(remoteToken)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Remote")
            } footer: {
                Text("Experimental. Listens on 127.0.0.1:\(String(RemoteServer.port)) only. To reach it from your phone, run `tailscale serve --bg \(String(RemoteServer.port))` and connect Berth Remote to wss://<this Mac>.<tailnet>.ts.net with the token.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 680)
        .onChange(of: isRemoteEnabled) {
            if remoteToken.isEmpty { remoteToken = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
            store.remote.update()
        }
    }
}
