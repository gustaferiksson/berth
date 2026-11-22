import SwiftUI

struct GeneralSettings: View {
    static let unloadIdleKey = "unloadIdleSessionsAfter"
    static let reviewKey = "reviewEnabled"
    static let conversationKey = "conversationEnabled"
    static let conversationViewKey = "conversationDefaultView"
    static let terminalBelowKey = "reviewTerminalBelow"
    static let worktreeKey = "startsInWorktree"
    static let languageServersKey = "languageServersEnabled"
    static let codexKey = "codexEnabled"
    static let keepsSessionsRunningKey = "keepsSessionsRunning"

    @AppStorage(NeedsYouAlerts.notifiesKey) private var notifiesWhenNeeded = true
    @AppStorage(unloadIdleKey) private var unloadIdleAfter = 14_400.0
    @Environment(Store.self) private var store
    @AppStorage(worktreeKey) private var startsInWorktree = false
    @AppStorage(codexKey) private var isCodexEnabled = false
    @AppStorage(keepsSessionsRunningKey) private var keepsSessionsRunning = false
    @AppStorage(ControlService.enabledKey) private var isControlEnabled = false
    @State private var control = ControlInstaller()

    var body: some View {
        Form {
            Section {
                Toggle("Start new sessions in a worktree", isOn: $startsInWorktree)
            } header: {
                Text("New Sessions")
            } footer: {
                Text("Sessions started in a folder inside a git repository get their own worktree and branch. Hold ⌥ in the launcher to start in the main checkout.")
            }
            Section {
                Toggle("Codex sessions", isOn: $isCodexEnabled)
                    .onChange(of: isCodexEnabled) { store.applyCodexSetting() }
            } header: {
                Text("Agents")
            } footer: {
                Text("Lists interactive Codex sessions from ~/.codex beside Claude's and resumes them in a tab. Hold ⌥⇧ in the launcher to start a new one. The Conversation view, context and pull request tags work for Codex. Status and needs-you alerts are still Claude only.")
            }
            Section {
                Toggle("Keep sessions running when Berth quits", isOn: $keepsSessionsRunning)
            } header: {
                Text("Quitting")
            } footer: {
                Text("New tabs run behind a small background helper, so quitting or updating Berth leaves shells and agents running and relaunching reattaches them. Closing a tab or unloading an idle session still ends it. Applies to tabs opened after you turn it on.")
            }
            Section {
                Toggle("Let sessions control Berth", isOn: $isControlEnabled)
                    .onChange(of: isControlEnabled) { store.control.update() }
                if isControlEnabled {
                    ControlInstallRows(installer: control)
                }
            } header: {
                Text("Agent Control")
            } footer: {
                Text("Sessions in tabs opened after you turn this on get a berth command that lists tabs, opens terminals in their folder, reads their output and closes the ones they opened. It talks to Berth over a private socket in Application Support.")
            }
            Section {
                Picker("Unload idle sessions after", selection: $unloadIdleAfter) {
                    Text("Never").tag(0.0)
                    Text("1 hour").tag(3600.0)
                    Text("4 hours").tag(14_400.0)
                    Text("1 day").tag(86_400.0)
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Unloaded sessions stay in the sidebar and resume when clicked. Pinned, working and waiting sessions stay loaded.")
            }
            Section {
                Toggle("Notify when a session needs you", isOn: $notifiesWhenNeeded)
            } header: {
                Text("Notifications")
            } footer: {
                Text("The Dock icon always shows how many sessions need you.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 800)
    }
}
