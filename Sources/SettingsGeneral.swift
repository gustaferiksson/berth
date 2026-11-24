import BerthCore
import SwiftUI

struct GeneralSettings: View {
    static let unloadIdleKey = "unloadIdleSessionsAfter"
    static let reviewKey = "reviewEnabled"
    static let conversationKey = "conversationEnabled"
    static let conversationViewKey = "conversationDefaultView"
    static let terminalBelowKey = "reviewTerminalBelow"
    static let worktreeKey = "startsInWorktree"
    static let languageServersKey = "languageServersEnabled"
    static let claudeKey = "claudeEnabled"
    static let claudeModelKey = "launchModel.claude"
    static let claudeEffortKey = "launchEffort.claude"
    static let defaultAgentKey = "newSessionAgent"
    static let codexKey = "codexEnabled"
    static let codexModelKey = "launchModel.codex"
    static let codexEffortKey = "launchEffort.codex"
    static let keepsSessionsRunningKey = "keepsSessionsRunning"
    static let pullRequestPromptKey = "pullRequestPrompt"
    static let defaultPullRequestPrompt = "Summarize PR #{number} ({url})."

    @AppStorage(NeedsYouAlerts.notifiesKey) private var notifiesWhenNeeded = true
    @AppStorage(unloadIdleKey) private var unloadIdleAfter = 14_400.0
    @Environment(Store.self) private var store
    @AppStorage(worktreeKey) private var startsInWorktree = false
    @AppStorage(claudeKey) private var isClaudeEnabled = true
    @AppStorage(pullRequestPromptKey) private var pullRequestPrompt = defaultPullRequestPrompt
    @AppStorage(codexKey) private var isCodexEnabled = false
    @AppStorage(defaultAgentKey) private var defaultAgent = Agent.claude.rawValue
    @AppStorage(claudeModelKey) private var claudeModel = ""
    @AppStorage(claudeEffortKey) private var claudeEffort = ""
    @AppStorage(codexModelKey) private var codexModel = ""
    @AppStorage(codexEffortKey) private var codexEffort = ""
    @AppStorage(keepsSessionsRunningKey) private var keepsSessionsRunning = false
    @AppStorage(ControlService.enabledKey) private var isControlEnabled = false
    @State private var control = ControlInstaller()
    @AppStorage(BrowserModel.searchKey) private var search = BrowserSearch.duckDuckGo
    @AppStorage(BrowserModel.persistentDataKey) private var keepsWebsiteData = false
    @AppStorage(BrowserModel.linksKey) private var linkTarget = BrowserLinkTarget.defaultBrowser

    private var codexModels: [CodexModel] { CodexModels.load(from: Store.codexDirectory) }

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
                TextField("Opening prompt", text: $pullRequestPrompt, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...6)
                HStack {
                    Spacer()
                    Button("Reset to Default") { pullRequestPrompt = Self.defaultPullRequestPrompt }
                        .disabled(pullRequestPrompt == Self.defaultPullRequestPrompt)
                }
            } header: {
                Text("Pull Requests")
            } footer: {
                Text("Sent as the first prompt when you open a pull request or an issue's pull requests in a new session. Use {number}, {url} and {repo} (owner/name) anywhere in it. Leave it empty to open the session without a prompt.")
            }
            Section {
                if isClaudeEnabled, isCodexEnabled {
                    Picker("New sessions start with", selection: $defaultAgent) {
                        ForEach(Agent.allCases, id: \.self) { Text($0.name).tag($0.rawValue) }
                    }
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Hold ⌥⇧ in the launcher to start the other agent. At least one stays on.")
            }
            AgentSection(
                harness: .claude,
                isEnabled: $isClaudeEnabled,
                isLocked: !isCodexEnabled,
                model: $claudeModel,
                effort: $claudeEffort,
                models: ClaudeLaunch.models.map { (slug: $0, name: $0.capitalized) },
                efforts: ClaudeLaunch.efforts,
                footer: "Lists Claude sessions from ~/.claude. Model and effort apply per launch. Berth never edits settings.json."
            ) { store.refresh() }
            AgentSection(
                harness: .codex,
                isEnabled: $isCodexEnabled,
                isLocked: !isClaudeEnabled,
                model: $codexModel,
                effort: $codexEffort,
                models: codexModels.map { (slug: $0.slug, name: $0.displayName) },
                efforts: codexModels.first { $0.slug == codexModel }?.efforts ?? codexModels.flatMap(\.efforts).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                footer: "Lists Codex sessions from ~/.codex. Model and effort apply per launch. Berth never edits config.toml."
            ) { store.applyCodexSetting() }
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
                Picker("Search with", selection: $search) {
                    ForEach(BrowserSearch.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Conversation links open in", selection: $linkTarget) {
                    Text("Default browser").tag(BrowserLinkTarget.defaultBrowser)
                    Text("Berth’s browser").tag(BrowserLinkTarget.berth)
                }
                Toggle("Keep website data between launches", isOn: $keepsWebsiteData)
            } header: {
                Text("Browser")
            } footer: {
                Text("The Browser pane (⇧⌘B) forgets cookies and logins when Berth quits. Keep website data so logins stick; it applies to tabs opened after you change it.")
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
        .frame(height: 1180)
    }
}

private struct AgentSection: View {
    let harness: Harness
    @Binding var isEnabled: Bool
    let isLocked: Bool
    @Binding var model: String
    @Binding var effort: String
    let models: [(slug: String, name: String)]
    let efforts: [String]
    let footer: String
    let onToggle: () -> Void

    var body: some View {
        Section {
            Toggle("Enabled", isOn: $isEnabled)
                .disabled(isEnabled && isLocked)
                .onChange(of: isEnabled, onToggle)
            if isEnabled {
                Picker("Model", selection: $model) {
                    Text("Default").tag("")
                    ForEach(models, id: \.slug) { Text($0.name).tag($0.slug) }
                }
                .onChange(of: model) {
                    if !effort.isEmpty, !efforts.contains(effort) { effort = "" }
                }
                Picker("Reasoning effort", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
        } header: {
            Label {
                Text(harness.name)
            } icon: {
                Image(harness.asset)
            }
        } footer: {
            Text(footer)
        }
    }
}
