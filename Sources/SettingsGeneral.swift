import BerthCore
import SwiftUI

struct GeneralSettings: View {
    static let unloadIdleKey = "unloadIdleSessionsAfter"
    static let reviewKey = "reviewEnabled"
    static let worktreeKey = "startsInWorktree"
    static let languageServersKey = "languageServersEnabled"

    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage(NeedsYouAlerts.notifiesKey) private var notifiesWhenNeeded = true
    @AppStorage(unloadIdleKey) private var unloadIdleAfter = 14_400.0
    @AppStorage(worktreeKey) private var startsInWorktree = false
    @AppStorage(reviewKey) private var isReviewEnabled = false
    @AppStorage(languageServersKey) private var areLanguageServersEnabled = false
    @AppStorage(LanguageServerEntry.storageKey) private var configuredServers = ""
    @State private var editedServer: LanguageServerEntry?
    @AppStorage(RemoteServer.enabledKey) private var isRemoteEnabled = false
    @AppStorage(RemoteServer.tokenKey) private var remoteToken = ""
    @State private var isTokenShown = false
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
                Toggle("Start new sessions in a worktree", isOn: $startsInWorktree)
                Picker("Unload idle sessions after", selection: $unloadIdleAfter) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(3600.0)
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
                if isReviewEnabled {
                    Toggle("Enable language servers", isOn: $areLanguageServersEnabled)
                }
            } header: {
                Text("Review")
            } footer: {
                Text("Experimental. Adds Review Changes (⇧⌘R) to Claude sessions: a diff of the session’s branch and uncommitted work, with line comments sent back to Claude.")
                if isReviewEnabled {
                    Text("Language servers add go to definition (⌘-click), hover and diagnostics. They and the build scripts they run execute the repository’s code.")
                }
            }
            if isReviewEnabled, areLanguageServersEnabled {
                Section {
                    ForEach(servers) { $server in
                        LabeledContent {
                            Button("Edit…") { editedServer = server }
                            Toggle("Enabled", isOn: $server.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        } label: {
                            Text(server.name)
                            Text(([server.command] + server.arguments).joined(separator: " "))
                        }
                    }
                    Button("Add Server…") { editedServer = LanguageServerEntry(name: "", command: "") }
                    let unreadable = LanguageServerEntry.stored(configuredServers).unreadable.count
                    if unreadable > 0 {
                        Label("^[\(unreadable) entry](inflect: true) in languageServers couldn’t be read and won’t run.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Language Servers")
                } footer: {
                    Text("A server starts in the nearest folder above the file with one of its root markers, or the repository root when it has none. Commands resolve from that folder’s node_modules/.bin, then PATH.")
                }
            }
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
                Text("Remote")
            } footer: {
                Text("Experimental. Listens on 127.0.0.1:\(String(RemoteServer.port)) only. To reach it from your phone, run `tailscale serve --bg \(String(RemoteServer.port))` and connect Berth Remote to wss://<this Mac>.<tailnet>.ts.net with the token. Regenerating the token disconnects every phone.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 680)
        .sheet(item: $editedServer) { LanguageServerEditor(server: $0, servers: servers) }
        .onChange(of: isRemoteEnabled) {
            if remoteToken.isEmpty { remoteToken = Data((0..<24).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString() }
            store.remote.update()
        }
        .onChange(of: remoteToken) { store.remote.update() }
    }

    private var servers: Binding<[LanguageServerEntry]> {
        Binding {
            LanguageServerEntry.configured(configuredServers)
        } set: {
            configuredServers = LanguageServerEntry.storage($0, keeping: LanguageServerEntry.stored(configuredServers).unreadable)
        }
    }
}
