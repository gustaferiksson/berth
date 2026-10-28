import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        NavigationSplitView {
            Sidebar()
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
            .navigationTitle(selected.map { URL(filePath: $0.cwd).lastPathComponent } ?? "Berth")
            .navigationSubtitle(selected?.cwd ?? "")
            .toolbar {
                Button("New Terminal", systemImage: "apple.terminal") {
                    store.openShell(cwd: selected?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
                }
                .help("New terminal")
            }
        }
        .alert("Running Elsewhere", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.notice ?? "")
        }
    }
}
