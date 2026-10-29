import BerthCore
import GhosttyTerminal
import SwiftUI

enum SidebarPosition: String {
    case left
    case right
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @AppStorage("terminalPanelPosition") private var panelPosition = PanelPosition.bottom
    @AppStorage("terminalPanelWidth") private var panelWidth = 420.0
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage("trailingSidebarWidth") private var trailingSidebarWidth = 300.0
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @AppStorage("showsTrailingSidebar") private var showsTrailingSidebar = true
    @Environment(\.appearsActive) private var appearsActive
    @State private var pulse = WorkingPulse()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        let isTrailing = sidebarPosition == .right
        let isPanelInspectorShown = !isTrailing && panelPosition == .side && store.isPanelOpen && !store.shells.isEmpty
        NavigationSplitView(columnVisibility: Binding(get: { isTrailing ? .detailOnly : columnVisibility }, set: { if !isTrailing { columnVisibility = $0 } })) {
            if isTrailing {
                Color.clear
                    .toolbar(removing: .sidebarToggle)
            } else {
                Sidebar()
                    .scrollContentBackground(.hidden)
                    .background(store.theme.background ?? .clear)
                    .overlay(alignment: .trailing) { Hairline(axis: .vertical).ignoresSafeArea() }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 440)
            }
        } detail: {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if isTrailing && panelPosition == .side {
                        TerminalPanel(available: geometry.size, edge: .leading)
                    }
                    VStack(spacing: 0) {
                        sessions
                            .overlay {
                                if let mode = store.launcherMode {
                                    ZStack(alignment: .top) {
                                        Color.clear
                                            .contentShape(.rect)
                                            .onTapGesture { store.launcherMode = nil }
                                        Launcher(mode: mode)
                                            .id(mode)
                                            .padding(.top, 120)
                                    }
                                }
                            }
                            .overlay(alignment: .top) {
                                if let restart = store.updater.pendingRestart {
                                    RestartBanner(version: restart.version, deadline: restart.deadline)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                            }
                            .animation(.default, value: store.updater.pendingRestart?.deadline)
                        if panelPosition == .bottom {
                            TerminalPanel(available: geometry.size, edge: .bottom)
                        }
                    }
                }
            }
            .inspector(isPresented: Binding(get: { isTrailing ? showsTrailingSidebar : isPanelInspectorShown }, set: { if isTrailing { showsTrailingSidebar = $0 } else { store.isPanelOpen = $0 } })) {
                if isTrailing {
                    Sidebar()
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .background(store.theme.background ?? .clear)
                        .overlay(alignment: .leading) { Hairline(axis: .vertical).ignoresSafeArea() }
                        .onGeometryChange(for: Double.self) { $0.size.width } action: { if store.persistsTabs && $0 >= 220 { trailingSidebarWidth = $0 } }
                        .inspectorColumnWidth(min: 220, ideal: trailingSidebarWidth, max: 440)
                } else {
                    PanelBody(isShown: true)
                        .background(store.theme.background ?? .clear)
                        .overlay(alignment: .leading) { Hairline(axis: .vertical).ignoresSafeArea() }
                        .onGeometryChange(for: Double.self) { $0.size.width } action: { panelWidth = $0 }
                        .inspectorColumnWidth(min: 240, ideal: panelWidth, max: 900)
                }
            }
            .transaction(value: isPanelInspectorShown) { $0.disablesAnimations = true }
            .background(store.theme.background ?? .clear)
            .navigationTitle(store.isHarborShown ? "Harbor" : selected.map { $0.title(terminalTitle: $0.terminal.title, sessionTitle: store.sessionTitle(of: $0)) } ?? "Berth")
            .navigationSubtitle(store.isHarborShown ? "" : selected.map { ($0.cwd as NSString).abbreviatingWithTildeInPath } ?? "")
            .toolbar {
                ToolbarItem(placement: isTrailing ? .navigation : .automatic) {
                    Button(store.isPanelOpen ? "Hide Terminal Panel" : "Show Terminal Panel", systemImage: "apple.terminal") {
                        store.toggleTerminalPanel()
                    }
                    .help("Terminal panel (⌘J)")
                }
                if isTrailing {
                    ToolbarItem {
                        Button(showsTrailingSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.right") {
                            showsTrailingSidebar.toggle()
                        }
                        .help(showsTrailingSidebar ? "Hide Sidebar" : "Show Sidebar")
                    }
                }
            }
        }
        .containerBackground(store.theme.background ?? .clear, for: .window)
        .environment(\.ghosttyTheme, store.theme)
        .environment(pulse)
        .onChange(of: appearsActive, initial: true) { pulse.isRunning = appearsActive || Snapshot.forcesPulse }
        .preferredColorScheme(store.theme.isDark ? .dark : .light)
        .background(WindowChrome(color: store.theme.background))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.refreshPullRequests() }
        .onChange(of: store.isStatsRequested) {
            guard store.isStatsRequested else { return }
            store.isStatsRequested = false
            openWindow(id: "stats")
        }
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
                let isSelected = tab.id == store.selectedTabID && !store.isHarborShown
                TerminalSurfaceView(context: tab.terminal)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .onChange(of: isSelected, initial: true) { tab.terminal.isSurfaceVisible = isSelected }
            }
            if store.isHarborShown {
                Harbor()
            } else if store.tabs.isEmpty {
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

struct WindowChrome: NSViewRepresentable {
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
