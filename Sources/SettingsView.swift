import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, sidebar, terminal, conversation, review, github, browser, remote, about
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var storedTab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: tab) {
            SwiftUI.Tab("General", systemImage: "gearshape", value: .general) { GeneralSettings() }
            SwiftUI.Tab("Sidebar", systemImage: "sidebar.left", value: .sidebar) { SidebarSettings() }
            SwiftUI.Tab("Terminal", systemImage: "terminal", value: .terminal) { TerminalSettings() }
            SwiftUI.Tab("Conversation", systemImage: "bubble.left.and.text.bubble.right", value: .conversation) { ConversationSettings() }
            SwiftUI.Tab("Review", systemImage: "plusminus.circle", value: .review) { ReviewSettings() }
            SwiftUI.Tab("GitHub", systemImage: "checklist", value: .github) { GitHubSettings() }
            SwiftUI.Tab("Browser", systemImage: "globe", value: .browser) { BrowserSettings() }
            SwiftUI.Tab("Remote", systemImage: "iphone.gen3.radiowaves.left.and.right", value: .remote) { RemoteSettings() }
            SwiftUI.Tab("About", systemImage: "info.circle", value: .about) { AboutSettings() }
        }
        .frame(width: 560)
    }

    private var tab: Binding<SettingsTab> {
        Binding {
            SettingsTab(rawValue: storedTab) ?? (storedTab == "appearance" ? .sidebar : .general)
        } set: { newTab in
            storedTab = newTab.rawValue
        }
    }
}
