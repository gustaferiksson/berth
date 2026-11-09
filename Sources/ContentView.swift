import BerthCore
import GhosttyTerminal
import SwiftUI

enum SidebarPosition: String {
    case left
    case right
}

struct ContentView: View {
    @Environment(Store.self) private var store
    @AppStorage("sidebarPosition") private var sidebarPosition = SidebarPosition.left
    @AppStorage("trailingSidebarWidth") private var trailingSidebarWidth = 300.0
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @AppStorage("showsTrailingSidebar") private var showsTrailingSidebar = true
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var store = store
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        let isTrailing = sidebarPosition == .right
        NavigationSplitView(columnVisibility: Binding(get: { isTrailing ? .detailOnly : columnVisibility }, set: { if !isTrailing { columnVisibility = $0 } })) {
            if isTrailing {
                Color.clear
                    .toolbar(removing: .sidebarToggle)
            } else {
                Sidebar()
                    .scrollContentBackground(.hidden)
                    .background(store.theme.background ?? .clear)
                    .overlay(alignment: .trailing) { Hairline(axis: .vertical).ignoresSafeArea() }
                    .navigationSplitViewColumnWidth(min: 220, ideal: Snapshot.sidebarWidth, max: 440)
            }
        } detail: {
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
            .inspector(isPresented: Binding(get: { isTrailing && showsTrailingSidebar }, set: { if isTrailing { showsTrailingSidebar = $0 } })) {
                Sidebar()
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .background(store.theme.background ?? .clear)
                    .overlay(alignment: .leading) { Hairline(axis: .vertical).ignoresSafeArea() }
                    .background(ScrollPocketSeparatorRemover())
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { if store.persistsTabs && $0 >= 220 { trailingSidebarWidth = $0 } }
                    .inspectorColumnWidth(min: 220, ideal: trailingSidebarWidth, max: 440)
            }
            .background(store.theme.background ?? .clear)
            .background {
                if let selected, !store.isHarborShown {
                    TabTitle(tab: selected, terminal: selected.terminal, sessionTitle: store.sessionTitle(of: selected))
                } else {
                    Color.clear.navigationTitle(store.isHarborShown ? "Harbor" : "Berth")
                }
            }
            .toolbar {
                ToolbarItem(placement: isTrailing ? .navigation : .automatic) {
                    Button(AppAction.switchTerminal.title, systemImage: AppAction.switchTerminal.symbol) {
                        AppAction.switchTerminal.perform(on: store)
                    }
                    .help("Switch between terminal and Claude (⌘J)")
                }
                if isReviewEnabled, AppAction.reviewChanges.isAvailable(in: store) {
                    ToolbarItem {
                        Toggle(AppAction.reviewChanges.title, systemImage: AppAction.reviewChanges.symbol, isOn: Binding(get: { store.reviewSessionID != nil }, set: { _ in AppAction.reviewChanges.perform(on: store) }))
                            .toggleStyle(.button)
                            .help("Review Changes (⇧⌘R)")
                    }
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
        .preferredColorScheme(store.theme.isDark ? .dark : .light)
        .background(WindowChrome(color: store.theme.background))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.isAppActive = true
            store.refreshPullRequests()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in store.isAppActive = false }
        .onChange(of: isReviewEnabled) {
            guard !isReviewEnabled else { return }
            store.reviewSessionID = nil
            store.reviewModels = [:]
        }
        .onChange(of: store.isStatsRequested) {
            guard store.isStatsRequested else { return }
            store.isStatsRequested = false
            openWindow(id: "stats")
        }
        .onChange(of: store.isSettingsRequested) {
            guard store.isSettingsRequested else { return }
            store.isSettingsRequested = false
            openSettings()
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
        let reviewed = isReviewEnabled ? store.tabs.first { $0.id == store.selectedTabID && $0.sessionID != nil && $0.sessionID == store.reviewSessionID } : nil
        return ZStack {
            ForEach(store.tabs) { tab in
                let isSelected = tab.id == store.selectedTabID && !store.isHarborShown && reviewed == nil
                TerminalSurfaceView(context: tab.terminal)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .onChange(of: isSelected, initial: true) { tab.terminal.isSurfaceVisible = isSelected }
            }
            if store.isHarborShown {
                Harbor()
            } else if let sessionID = reviewed?.sessionID, let model = store.reviewModels[sessionID] {
                ReviewView(sessionID: sessionID, model: model)
                    .id(sessionID)
            } else if store.tabs.isEmpty {
                ContentUnavailableView("No Open Session", systemImage: "terminal", description: Text("Pick a session in the sidebar, or start one with ⌘N."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TabTitle: View {
    let tab: Tab
    @ObservedObject var terminal: TerminalViewState
    let sessionTitle: String?

    var body: some View {
        Color.clear
            .navigationTitle(tab.title(terminalTitle: terminal.title, sessionTitle: sessionTitle))
            .navigationSubtitle((tab.folder as NSString).abbreviatingWithTildeInPath)
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

// AppKit gives an inspector column's scroll pocket a thin-film edge with a separator line, and no public API turns it off.
private struct ScrollPocketSeparatorRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var candidates = view.superview?.superview.map { [$0] } ?? []
            while let next = candidates.popLast() {
                if next.responds(to: Selector(("setAllowsSeparator:"))) { next.setValue(false, forKey: "allowsSeparator") }
                candidates.append(contentsOf: next.subviews)
            }
        }
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
