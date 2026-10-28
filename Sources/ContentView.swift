import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selectedTabID) {
                ForEach(store.tabs) { tab in
                    Label(tab.terminal.title.isEmpty ? "Terminal" : tab.terminal.title, systemImage: "terminal")
                        .tag(tab.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
            .toolbar {
                Button("New Terminal", systemImage: "plus") {
                    store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                }
            }
        } detail: {
            ZStack {
                ForEach(store.tabs) { tab in
                    let isSelected = tab.id == store.selectedTabID
                    TerminalSurfaceView(context: tab.terminal)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .onChange(of: isSelected, initial: true) { tab.terminal.isSurfaceVisible = isSelected }
                }
            }
        }
    }
}
