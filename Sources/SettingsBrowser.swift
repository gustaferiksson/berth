import SwiftUI

struct BrowserSettings: View {
    @AppStorage(BrowserModel.searchKey) private var search = BrowserSearch.duckDuckGo
    @AppStorage(BrowserModel.persistentDataKey) private var keepsWebsiteData = false
    @AppStorage(BrowserModel.linksKey) private var linkTarget = BrowserLinkTarget.defaultBrowser
    @AppStorage(BrowserModel.githubLinksKey) private var opensGitHubInBerth = false
    @AppStorage(BrowserModel.appearanceKey) private var browserAppearance = BrowserAppearance.auto
    @AppStorage(BrowserModel.developerToolsKey) private var developerTools = true
    @AppStorage(BrowserAccess.policyKey) private var agentControl = AgentBrowserPolicy.ask

    var body: some View {
        Form {
            Section {
                Picker("Search with", selection: $search) {
                    ForEach(BrowserSearch.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Conversation links open in", selection: $linkTarget) {
                    Text("Default browser").tag(BrowserLinkTarget.defaultBrowser)
                    Text("Berth’s browser").tag(BrowserLinkTarget.berth)
                }
                Toggle("Open GitHub links in Berth’s browser", isOn: $opensGitHubInBerth)
                Picker("Web page appearance", selection: $browserAppearance) {
                    ForEach(BrowserAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Keep website data between launches", isOn: $keepsWebsiteData)
                Toggle("Developer tools", isOn: $developerTools)
                Picker("Agent browser control", selection: $agentControl) {
                    ForEach(AgentBrowserPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Auto page appearance follows macOS, not Berth’s theme. The Browser pane (⇧⌘B) forgets cookies and logins when Berth quits. Keep website data so logins stick for tabs opened after you change it. GitHub links can open in the current session’s Browser pane. Ask shows a prompt the first time each session’s agent uses the berth browser commands, and the answer lasts until Berth quits. Developer tools let you open Web Inspector from Page Actions or with ⌥⌘I.")
            }
        }
        .formStyle(.grouped)
    }
}
