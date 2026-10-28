import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @AppStorage("terminalPanelPosition") private var panelPosition = PanelPosition.bottom
    @AppStorage("terminalPanelWidth") private var panelWidth = 420.0

    var body: some View {
        @Bindable var store = store
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        NavigationSplitView {
            Sidebar()
                .scrollContentBackground(.hidden)
                .background(store.theme.background ?? .clear)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 440)
        } detail: {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    sessions
                    if panelPosition == .bottom {
                        TerminalPanel(available: geometry.size)
                    }
                }
            }
            .inspector(isPresented: Binding(get: { panelPosition == .right && store.isPanelOpen && !store.shells.isEmpty }, set: { store.isPanelOpen = $0 })) {
                PanelBody(isShown: true)
                    .background(store.theme.background ?? .clear)
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { panelWidth = $0 }
                    .inspectorColumnWidth(min: 240, ideal: panelWidth, max: 900)
            }
            .background(store.theme.background ?? .clear)
            .navigationTitle(selected.map { $0.title(terminalTitle: $0.terminal.title, sessionTitle: store.sessionTitle(of: $0)) } ?? "Berth")
            .navigationSubtitle(selected.map { ($0.cwd as NSString).abbreviatingWithTildeInPath } ?? "")
            .toolbar {
                Button(store.isPanelOpen ? "Hide Terminal Panel" : "Show Terminal Panel", systemImage: "apple.terminal") {
                    store.toggleTerminalPanel()
                }
                .help("Terminal panel (⌘J)")
            }
        }
        .containerBackground(store.theme.background ?? .clear, for: .window)
        .environment(\.ghosttyTheme, store.theme)
        .preferredColorScheme(store.theme.isDark ? .dark : .light)
        .background(WindowChrome(color: store.theme.background))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshPullRequests() }
    }
}


extension ContentView {
    private var sessions: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WindowChrome: NSViewRepresentable {
    let color: Color?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = color != nil
            window.backgroundColor = color.map(NSColor.init) ?? .windowBackgroundColor
        }
    }
}
