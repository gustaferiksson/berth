import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        NavigationSplitView {
            Sidebar()
                .scrollContentBackground(.hidden)
                .background(store.theme.background ?? .clear)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 440)
        } detail: {
            ZStack {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == store.selectedTabID
                    TerminalSurfaceView(context: tab.terminal)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .onChange(of: isSelected, initial: true) { tab.terminal.isSurfaceVisible = isSelected }
                }
                if store.tabs.isEmpty {
                    ContentUnavailableView("No Open Session", systemImage: "terminal", description: Text("Pick a session in the sidebar, or start one with + on a project."))
                }
            }
            .background(store.theme.background ?? .clear)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(selected.map { $0.title(terminalTitle: $0.terminal.title, sessionTitle: store.sessionTitle(of: $0)) } ?? "Berth")
            .navigationSubtitle(selected.map { ($0.cwd as NSString).abbreviatingWithTildeInPath } ?? "")
            .toolbar {
                Button("New Terminal", systemImage: "apple.terminal") {
                    store.openShell(cwd: selected?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
                }
                .help("New terminal")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(store.theme.background ?? .clear, for: .window)
        .environment(\.ghosttyTheme, store.theme)
        .preferredColorScheme(store.theme.isDark ? .dark : .light)
        .alert("Running Elsewhere", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.notice ?? "")
        }
    }
}

