import BerthCore
import GhosttyTerminal
import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @AppStorage("terminalPanelPosition") private var panelPosition = PanelPosition.bottom
    @AppStorage("terminalPanelWidth") private var panelWidth = 420.0
    @Environment(\.appearsActive) private var appearsActive
    @State private var pulse = WorkingPulse()

    var body: some View {
        @Bindable var store = store
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        let isInspectorShown = panelPosition == .right && store.isPanelOpen && !store.shells.isEmpty
        NavigationSplitView {
            Sidebar()
                .scrollContentBackground(.hidden)
                .background(store.theme.background ?? .clear)
                .overlay(alignment: .trailing) { Hairline(axis: .vertical).ignoresSafeArea() }
                .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 440)
                .toolbar {
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        Menu("Group By", systemImage: "square.grid.3x1.below.line.grid.1x2") {
                            Section("Group By") { GroupingMenuItems(store: store) }
                            Button("New Group…") { store.editingGroup = CustomGroup(name: "", rules: []) }
                        }
                        .menuIndicator(.hidden)
                        .help("Group By")
                    }
                }
        } detail: {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    sessions
                        .overlay {
                            if store.isLauncherPresented {
                                ZStack(alignment: .top) {
                                    Color.clear
                                        .contentShape(.rect)
                                        .onTapGesture { store.isLauncherPresented = false }
                                    Launcher()
                                        .padding(.top, 120)
                                }
                            }
                        }
                    if panelPosition == .bottom {
                        TerminalPanel(available: geometry.size)
                    }
                }
            }
            .inspector(isPresented: Binding(get: { isInspectorShown }, set: { store.isPanelOpen = $0 })) {
                PanelBody(isShown: true)
                    .background(store.theme.background ?? .clear)
                    .overlay(alignment: .leading) { Hairline(axis: .vertical).ignoresSafeArea() }
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { panelWidth = $0 }
                    .inspectorColumnWidth(min: 240, ideal: panelWidth, max: 900)
            }
            .transaction(value: isInspectorShown) { $0.disablesAnimations = true }
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
        .environment(pulse)
        .onChange(of: appearsActive, initial: true) { pulse.isRunning = appearsActive || Snapshot.forcesPulse }
        .preferredColorScheme(store.theme.isDark ? .dark : .light)
        .background(WindowChrome(color: store.theme.background))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshPullRequests() }
        .sheet(item: $store.editingGroup) { GroupEditor(group: $0) }
        .confirmationDialog("Delete “\(store.deletingGroup?.name ?? "")”?", isPresented: Binding(get: { store.deletingGroup != nil }, set: { if !$0 { store.deletingGroup = nil } }), presenting: store.deletingGroup) { group in
            Button("Delete Group", role: .destructive) { store.customGroups.removeAll { $0.id == group.id } }
        } message: { _ in
            Text("Its sessions go back to their automatic groups. No transcripts are deleted.")
        }
        .alert("Folder Not Found", isPresented: Binding(get: { store.missingFolder != nil }, set: { if !$0 { store.missingFolder = nil } }), presenting: store.missingFolder) { _ in
        } message: { folder in
            Text("\((folder as NSString).abbreviatingWithTildeInPath) no longer exists, so Claude can’t start there.")
        }
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
                ContentUnavailableView("No Open Session", systemImage: "terminal", description: Text("Pick a session in the sidebar, or start one with ⌘N."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Hairline: View {
    let axis: Axis
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(theme.foreground.opacity(0.1))
            .frame(width: axis == .vertical ? 1 / displayScale : nil, height: axis == .horizontal ? 1 / displayScale : nil)
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
