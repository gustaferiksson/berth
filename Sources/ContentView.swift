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
    @AppStorage(GeneralSettings.conversationKey) private var isConversationEnabled = false
    @AppStorage(GeneralSettings.languageServersKey) private var areLanguageServersEnabled = false
    @AppStorage(GeneralSettings.terminalBelowKey) private var isTerminalBelow = false
    @AppStorage(WindowBackdrop.transparencyKey) private var windowTransparency = 0.0
    @State private var sidebarYieldsToDiff = false
    @State private var keepsSidebarForDiff = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var store = store
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        let isTrailing = sidebarPosition == .right
        let reviewRoots = showsPanel ? store.sessionReviewModels.compactMap { $0.changes?.root } : []
        let folderWithoutRepository: String? = if showsPanel, let model = store.primaryReviewModel, case ReviewGitError.notARepository? = model.error { model.folder } else { nil }
        let reviewRequests = store.inbox?.count { $0.role == .reviewRequested } ?? 0
        NavigationSplitView(columnVisibility: Binding(get: { isTrailing ? (showsPanel ? .all : .detailOnly) : leadingSessions }, set: setLeadingColumn)) {
            if isTrailing {
                ReviewPanel()
                    .glassSidebarTint(store.theme)
                    .toolbar(removing: isReviewEnabled ? nil : .sidebarToggle)
                    .toolbar { ChangesToolbar(store: store, isReviewEnabled: isReviewEnabled) }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 272, max: 440)
            } else {
                Sidebar()
                    .glassSidebarTint(store.theme)
                    .navigationSplitViewColumnWidth(min: 220, ideal: Snapshot.sidebarWidth, max: 440)
            }
        } detail: {
            TerminalSplit(store: store, isDiffLeading: isTrailing, isDiffCollapsed: !showsPanel, isTerminalBelow: isTerminalBelow)
                .background { SplitWidthSettled(isActive: showsPanel, isTerminalBelow: isTerminalBelow, onSettle: yieldSidebarIfCramped) }
                .padding(EdgeInsets(top: 0, leading: 8, bottom: store.selectedConversationIsVisible ? 0 : 8, trailing: 8))
                .overlay {
                    if let mode = store.launcherMode {
                        ZStack(alignment: .top) {
                            Color.clear
                                .contentShape(.rect)
                                .onTapGesture { store.launcherMode = nil }
                            Launcher(mode: mode, query: store.launcherQuery)
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
                .overlay(alignment: .bottom) {
                    if !store.preparingPullRequests.isEmpty {
                        PullRequestPreparingBanner(count: store.preparingPullRequests.count, number: store.preparingPullRequests.count == 1 ? store.preparingPullRequests.first?.number : nil)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.default, value: store.preparingPullRequests)
                .animation(.default, value: store.updater.pendingRestart?.deadline)
                .background { Color.clear.glassEffect(.regular, in: .rect).ignoresSafeArea() }
                .background {
                    if let selected, !store.isHarborShown {
                        TabTitle(tab: selected, terminal: selected.terminal, sessionTitle: store.sessionTitle(of: selected))
                    } else {
                        Color.clear.navigationTitle(store.isHarborShown ? "Harbor" : "Berth")
                    }
                }
                .toolbar {
                    if reviewRequests > 0 {
                        ToolbarItem(placement: .automatic) {
                            Button {
                                store.launcherRole = .reviewRequested
                                store.launcherMode = .pullRequests
                            } label: {
                                Label("\(reviewRequests) to review", systemImage: "arrow.triangle.pull")
                                    .labelStyle(.titleAndIcon)
                                    .foregroundStyle(store.theme.needsYou)
                            }
                            .help(Text("^[\(reviewRequests) pull request](inflect: true) waiting for your review"))
                        }
                    }
                    if reviewRequests > 0 {
                        ToolbarSpacer(.fixed, placement: .automatic)
                    }
                    SessionToolbar(store: store, isReviewEnabled: isReviewEnabled)
                    if isReviewEnabled, !isTrailing, !store.showsSessionToolbar {
                        ToolbarItem(placement: .primaryAction) { panelToggle(symbol: "sidebar.right") }
                    }
                    if isTrailing, !showsSessions {
                        if store.showsSessionToolbar { ToolbarSpacer(.fixed, placement: .primaryAction) }
                        ToolbarItem(placement: .primaryAction) { sessionsToggle }
                    }
                }
        }
        .inspector(isPresented: Binding(get: { isTrailing ? showsSessions : showsPanel }, set: setInspector)) {
            if isTrailing {
                Sidebar()
                    .listStyle(.sidebar)
                    .glassSidebarTint(store.theme)
                    .background(ScrollPocketSeparatorRemover())
                    .onGeometryChange(for: Double.self) { $0.size.width } action: { if store.persistsTabs, $0 >= 220 { trailingSidebarWidth = $0 } }
                    .inspectorColumnWidth(min: 220, ideal: trailingSidebarWidth, max: 440)
                    .toolbar { ToolbarItem(placement: .primaryAction) { sessionsToggle } }
            } else {
                ReviewPanel()
                    .glassSidebarTint(store.theme)
                    .background(ScrollPocketSeparatorRemover())
                    .inspectorColumnWidth(min: 220, ideal: 272, max: 440)
                    .toolbar { ChangesToolbar(store: store, isReviewEnabled: isReviewEnabled) }
            }
        }
        .containerBackground(for: .window) { WindowBackdrop(chrome: store.theme.chrome, transparency: windowTransparency) }
        .environment(\.ghosttyTheme, store.theme)
        .preferredColorScheme(store.theme.isDark ? .dark : .light)
        .background(WindowChrome(color: store.theme.chrome, transparency: windowTransparency))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.isAppActive = true
            store.refreshPullRequests()
            store.refreshInbox()
            store.refreshIssueInbox()
            store.refreshLocalClones()
            Task {
                await store.refreshPlanUsage()
                await store.refreshCodexUsage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in store.isAppActive = false }
        .task(id: "\(selected?.sessionID ?? "")\n\(selected?.cwd ?? "")\(isReviewEnabled)") {
            guard isReviewEnabled, let selected, selected.kind == .claude, let sessionID = selected.sessionID else { return }

            await store.trackChangeSize(sessionID: sessionID, folder: selected.cwd)
        }
        .task(id: reviewRoots) { await store.watchReview(reviewRoots) }
        .task(id: folderWithoutRepository) { store.watchForRepository(in: folderWithoutRepository) }
        .onChange(of: showsPanel) {
            guard !showsPanel else {
                Task { for model in store.sessionReviewModels { await model.load() } }
                return
            }

            sidebarYieldsToDiff = false
            keepsSidebarForDiff = false
        }
        .onChange(of: isReviewEnabled) {
            if isReviewEnabled { store.prepareReviewModel() } else {
                store.reviewModels = [:]
                store.activeReviewRoots = [:]
            }
        }
        .onChange(of: isConversationEnabled) { store.syncConversations() }
        .onChange(of: areLanguageServersEnabled) {
            guard !areLanguageServersEnabled else { return }

            for model in store.reviewModels.values { model.language?.stop() }
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
        .alert("Couldn’t Open Pull Request", isPresented: Binding(get: { store.pullRequestFailure != nil }, set: { if !$0 { store.pullRequestFailure = nil } }), presenting: store.pullRequestFailure) { _ in
        } message: { message in
            Text(message)
        }
        .alert("Folder Not Found", isPresented: Binding(get: { store.missingFolder != nil }, set: { if !$0 { store.missingFolder = nil } }), presenting: store.missingFolder) { _ in
        } message: { folder in
            Text("\((folder as NSString).abbreviatingWithTildeInPath) no longer exists, so Claude can’t start there.")
        }
    }
}

extension ContentView {
    private var showsPanel: Bool {
        isReviewEnabled && store.showsReviewPanel && !store.isHarborShown
    }

    // The column and inspector echo programmatic changes and keep calling setters built for the other sidebar position, so these read live state and drop no-ops.
    private func setLeadingColumn(_ visibility: NavigationSplitViewVisibility) {
        if sidebarPosition == .left {
            if visibility != leadingSessions { setSessions(visibility) }
        } else if (visibility != .detailOnly) != showsPanel, isReviewEnabled, !store.isHarborShown {
            store.showsReviewPanel = visibility != .detailOnly
        }
    }

    private func setInspector(_ isPresented: Bool) {
        if sidebarPosition == .right {
            if isPresented != showsSessions { setSessions(isPresented ? .all : .detailOnly) }
        } else if isPresented != showsPanel, isReviewEnabled, !store.isHarborShown {
            store.showsReviewPanel = isPresented
        }
    }

    private var leadingSessions: NavigationSplitViewVisibility {
        sidebarYieldsToDiff ? .detailOnly : columnVisibility
    }

    private var showsSessions: Bool {
        !sidebarYieldsToDiff && (sidebarPosition == .right ? showsTrailingSidebar : columnVisibility != .detailOnly)
    }

    private func setSessions(_ visibility: NavigationSplitViewVisibility) {
        sidebarYieldsToDiff = false
        if visibility != .detailOnly { keepsSidebarForDiff = true }
        if sidebarPosition == .right { showsTrailingSidebar = visibility != .detailOnly } else { columnVisibility = visibility }
    }

    private func yieldSidebarIfCramped(splitWidth: Double) {
        guard showsSessions, !keepsSidebarForDiff, splitWidth > 0, splitWidth < TerminalSplit.diffMinimum + (isTerminalBelow ? 1 : TerminalSplit.terminalMinimum + 1) else { return }

        if columnVisibility == .automatic { columnVisibility = .all }
        sidebarYieldsToDiff = true
    }

    private var sessionsToggle: some View {
        Button(showsSessions ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.right") {
            setSessions(showsSessions ? .detailOnly : .all)
        }
        .help(showsSessions ? "Hide Sidebar" : "Show Sidebar")
    }

    private func panelToggle(symbol: String) -> some View {
        let action = AppAction.hideChanges.isAvailable(in: store) ? AppAction.hideChanges : .showChanges
        return Button(action.title, systemImage: symbol) { action.perform(on: store) }
            .help("\(action.title) (⇧⌘R)")
    }
}

// Reads the split's width in its own view so a live resize doesn't re-evaluate ContentView on every frame.
private struct SplitWidthSettled: View {
    let isActive: Bool
    let isTerminalBelow: Bool
    let onSettle: (Double) -> Void
    @State private var width = 0.0

    var body: some View {
        Color.clear
            .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
            .task(id: isActive ? [width, isTerminalBelow ? 1 : 0] : [0]) {
                guard isActive, await (try? Task.sleep(for: .milliseconds(300))) != nil else { return }

                onSettle(width)
            }
    }
}

private struct TerminalSplit: NSViewControllerRepresentable {
    static let diffMinimum = 440.0
    static let terminalMinimum = 360.0
    static let belowMinimum = 160.0
    static let gap = 8.0

    let store: Store
    let isDiffLeading: Bool
    let isDiffCollapsed: Bool
    let isTerminalBelow: Bool

    func makeNSViewController(context _: Context) -> TerminalSplitController {
        let split = TerminalSplitController()
        split.splitView = GapSplitView()
        split.splitView.identifier = NSUserInterfaceItemIdentifier("terminalSplit")
        let terminal = NSHostingController(rootView: TerminalArea(store: store))
        let diff = NSHostingController(rootView: ReviewDiffColumn(store: store))
        terminal.sizingOptions = []
        diff.sizingOptions = []
        for card in [terminal.view, diff.view] {
            card.wantsLayer = true
            card.layer?.cornerRadius = CardBorder.radius
            card.layer?.cornerCurve = .continuous
            card.layer?.masksToBounds = true
        }
        let terminalItem = NSSplitViewItem(viewController: terminal)
        let diffItem = NSSplitViewItem(viewController: diff)
        diffItem.canCollapse = true
        diffItem.isCollapsed = isDiffCollapsed
        split.splitView.isVertical = !isTerminalBelow
        split.splitViewItems = isDiffLeading || isTerminalBelow ? [diffItem, terminalItem] : [terminalItem, diffItem]
        return split
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController _: TerminalSplitController, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSViewController(_ split: TerminalSplitController, context _: Context) {
        guard let diff = split.diff else { return }

        let leadsDiff = isDiffLeading || isTerminalBelow
        let flipsOrientation = split.splitView.isVertical == isTerminalBelow
        if flipsOrientation { split.splitView.isVertical = !isTerminalBelow }
        if (split.splitViewItems.first === diff) != leadsDiff {
            split.removeSplitViewItem(diff)
            split.insertSplitViewItem(diff, at: leadsDiff ? 0 : 1)
        }
        if flipsOrientation {
            split.splitView.adjustSubviews()
            split.splitView.layoutSubtreeIfNeeded()
            split.fitDiff(preferring: 760)
        }
        guard diff.isCollapsed != isDiffCollapsed else { return }

        diff.isCollapsed = isDiffCollapsed
        guard !isDiffCollapsed else { return }

        split.splitView.layoutSubtreeIfNeeded()
        split.fitDiff(preferring: 760)
    }
}

private final class GapSplitView: NSSplitView {
    override var dividerThickness: CGFloat { subviews.contains(where: isSubviewCollapsed) ? 0 : TerminalSplit.gap }

    override func drawDivider(in _: NSRect) {}
}

// Width minimums as constraints (minimumThickness too) loop AppKit's constraint pass until it throws once the window can't fit them, so the divider is moved after layout instead.
private final class TerminalSplitController: NSSplitViewController {
    static let belowRatioKey = "reviewTerminalBelowRatio"
    static let belowRatioDefault = 0.6

    var diff: NSSplitViewItem? {
        splitViewItems.first { $0.viewController is NSHostingController<ReviewDiffColumn> }
    }

    private var laidOutSize = CGSize.zero

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !splitView.isVertical, NSApp.currentEvent?.type == .leftMouseDragged, let diff, !diff.isCollapsed else { return }

        UserDefaults.standard.set(diff.viewController.view.frame.height / (splitView.bounds.height - splitView.dividerThickness), forKey: Self.belowRatioKey)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard splitView.bounds.size != laidOutSize else { return }

        let preferred: CGFloat? = laidOutSize == .zero ? 760 : nil
        laidOutSize = splitView.bounds.size
        DispatchQueue.main.async { [weak self] in self?.fitDiff(preferring: preferred) }
    }

    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposed: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        splitView.isVertical ? proposed : min(max(proposed, TerminalSplit.belowMinimum), splitView.bounds.height - TerminalSplit.belowMinimum - splitView.dividerThickness)
    }

    func fitDiff(preferring preferred: CGFloat?) {
        guard let diff, !diff.isCollapsed else { return }

        let isBelow = !splitView.isVertical
        let total = isBelow ? splitView.bounds.height : splitView.bounds.width
        let current = isBelow ? diff.viewController.view.frame.height : diff.viewController.view.frame.width
        let diffMinimum = isBelow ? TerminalSplit.belowMinimum : TerminalSplit.diffMinimum
        let terminalMinimum = isBelow ? TerminalSplit.belowMinimum : TerminalSplit.terminalMinimum
        let ratio = UserDefaults.standard.object(forKey: Self.belowRatioKey) as? Double ?? Self.belowRatioDefault
        let wanted = isBelow ? preferred.map { _ in ratio * (total - splitView.dividerThickness) } : preferred
        let size = min(max(wanted ?? current, diffMinimum), max(diffMinimum, total - terminalMinimum - splitView.dividerThickness))
        guard abs(size - current) >= 1 else { return }

        splitView.setPosition(splitViewItems.first === diff ? size : total - size - splitView.dividerThickness, ofDividerAt: 0)
    }
}

private struct TerminalArea: View {
    let store: Store
    @AppStorage(GeneralSettings.conversationKey) private var isConversationEnabled = false

    var body: some View {
        ZStack {
            ForEach(store.tabs) { tab in
                let isSelected = tab.id == store.selectedTabID && !store.isHarborShown
                let model = isSelected && isConversationEnabled ? store.conversationModels[tab.id] : nil
                let showsSurface = isSelected && model == nil
                TerminalSurfaceView(context: tab.terminal)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .opacity(showsSurface ? 1 : 0)
                    .allowsHitTesting(showsSurface)
                    .onChange(of: showsSurface, initial: true) { tab.terminal.isSurfaceVisible = showsSurface }
                if let model {
                    ConversationView(model: model, tab: tab)
                }
            }
            if store.isHarborShown {
                Harbor()
            } else if store.tabs.isEmpty {
                ContentUnavailableView("No Open Session", systemImage: "terminal", description: Text("Pick a session in the sidebar, or start one with ⌘N."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if store.terminalSearch != nil {
                TerminalFindBar()
                    .padding(12)
            }
        }
        .background(store.theme.background ?? Color(nsColor: .textBackgroundColor))
        .overlay { CardBorder() }
        .environment(store)
        .environment(\.ghosttyTheme, store.theme)
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

struct CardBorder: View {
    static let radius = 12.0

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(theme.foreground.opacity(0.1))
            .allowsHitTesting(false)
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

private extension View {
    func glassSidebarTint(_: GhosttyTheme) -> some View {
        scrollContentBackground(.hidden)
    }
}

// AppKit gives an inspector column's scroll pocket a thin-film edge with a separator line, and no public API turns it off.
private struct ScrollPocketSeparatorRemover: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            var candidates = view.superview?.superview.map { [$0] } ?? []
            while let next = candidates.popLast() {
                if next.responds(to: Selector(("setAllowsSeparator:"))) { next.setValue(false, forKey: "allowsSeparator") }
                candidates.append(contentsOf: next.subviews)
            }
        }
    }
}

struct WindowBackdrop: View {
    static let transparencyKey = "windowTransparency"
    static let maxTransparency = 0.8

    let chrome: Color?
    let transparency: Double

    var body: some View {
        if transparency > 0 {
            ZStack {
                BehindWindowBlur()
                (chrome ?? Color(nsColor: .windowBackgroundColor)).opacity(1 - min(transparency, Self.maxTransparency))
            }
        } else {
            chrome ?? .clear
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        // swiftlint:disable:next hand_rolled_material
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}

struct WindowChrome: NSViewRepresentable {
    let color: Color?
    var transparency = 0.0

    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.titlebarAppearsTransparent = color != nil
            window.isOpaque = transparency == 0
            window.backgroundColor = transparency > 0 ? .clear : color.map(NSColor.init) ?? .windowBackgroundColor
        }
    }
}
