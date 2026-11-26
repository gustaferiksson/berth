import AppKit
import BerthCore
import SwiftUI
import WebKit

struct BrowserPane: View {
    let store: Store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let browser = store.browser
        let tab = browser.shownTab
        VStack(spacing: 0) {
            BrowserHeader(browser: browser, tab: tab)
            Group {
                if let tab, tab.url != nil {
                    BrowserWebView(tab: tab)
                } else {
                    ContentUnavailableView {
                        Label("New Tab", systemImage: "globe")
                    } description: {
                        Text("Type an address, or words to search with \(BrowserSearch(rawValue: UserDefaults.standard.string(forKey: BrowserModel.searchKey) ?? "")?.title ?? BrowserSearch.duckDuckGo.title)")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if size.width > 0, size.height > 0 { browser.lastPaneSize = size }
            }
            .background(theme.background ?? Color(nsColor: .textBackgroundColor))
            .clipShape(.rect(cornerRadius: CardBorder.radius, style: .continuous))
            .overlay { CardBorder() }
        }
    }
}

private struct BrowserHeader: View {
    static let controlSize: CGFloat = 32
    private static let wideSpacing: CGFloat = 8
    private static let compactSpacing: CGFloat = 6
    private static let compactThreshold: CGFloat = 640

    let browser: BrowserModel
    let tab: BrowserTab?
    @State private var width: CGFloat = 0
    @State private var pinnedViewportWidth: CGFloat = 0
    @State private var editingTabID: UUID?

    var body: some View {
        let pinned = browser.pinned
        let sessionTabs = browser.sessionKey.map(browser.tabs) ?? []
        let selectedSession = sessionTabs.first { $0 === tab }
        let selectedPinned = pinned.first { $0 === tab }
        let isCompact = width < Self.compactThreshold
        let spacing = isCompact ? Self.compactSpacing : Self.wideSpacing
        let pinnedWidth = min(
            CGFloat(pinned.count) * (Self.controlSize + spacing) - spacing,
            max(Self.controlSize, width * 0.25)
        )

        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                if !isCompact { navigationControls }
                if !pinned.isEmpty || !sessionTabs.isEmpty {
                    HStack(spacing: spacing) {
                        if !pinned.isEmpty {
                            if selectedPinned == nil {
                                pinnedTabs(pinned, spacing: spacing)
                                    .frame(width: pinnedWidth)
                            } else {
                                expandedPinnedTabs(pinned, selectedPinned: selectedPinned, spacing: spacing, isCompact: isCompact)
                            }
                        }
                        if !sessionTabs.isEmpty {
                            BrowserSessionTabs(browser: browser, tabs: sessionTabs, selection: selectedSession, isCompact: isCompact, editingTabID: $editingTabID, select: select, dropAtEnd: dropIntoSession)
                        }
                    }
                }
                if selectedSession == nil, selectedPinned == nil {
                    BrowserAddressField(browser: browser, tab: tab, isMerged: false, isCompact: isCompact)
                        .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
                        .frame(height: Self.controlSize)
                }
                if selectedSession != nil || selectedPinned != nil { Spacer(minLength: 0) }
                trailingActions(tabs: pinned + sessionTabs)
                BrowserDownloadsButton(browser: browser)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, spacing)
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func expandedPinnedTabs(_ pinned: [BrowserTab], selectedPinned: BrowserTab?, spacing: CGFloat, isCompact: Bool) -> some View {
        let circlesWidth = CGFloat(pinned.count - 1) * (Self.controlSize + spacing)
        let idealActive = selectedPinned.map { editingTabID == $0.id } == true ? BrowserSessionTabs.editingWidth : BrowserSessionTabs.maximumTabWidth
        let activeWidth = min(idealActive, max(BrowserSessionTabs.minimumActiveWidth, pinnedViewportWidth - circlesWidth))
        let selection = pinned.first { $0 === tab }?.id
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: spacing) {
                    ForEach(pinned) { pinnedTab in
                        let isSelected = pinnedTab === tab
                        BrowserHeaderTab(browser: browser, tab: pinnedTab, isPinned: true, isSelected: isSelected, isCompact: isCompact, editingTabID: $editingTabID) { select(pinnedTab) }
                            .frame(width: isSelected ? activeWidth : Self.controlSize)
                            .id(pinnedTab.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(minWidth: BrowserSessionTabs.minimumActiveWidth, maxWidth: circlesWidth + idealActive)
            .frame(height: Self.controlSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pinnedViewportWidth = $0 }
            .onChange(of: selection, initial: true) {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
        }
    }

    private func pinnedTabs(_ pinned: [BrowserTab], spacing: CGFloat) -> some View {
        let selection = pinned.first { $0 === tab }?.id
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: spacing) {
                    ForEach(pinned) { pinnedTab in
                        BrowserHeaderTab(browser: browser, tab: pinnedTab, isPinned: true, isSelected: pinnedTab === tab, editingTabID: $editingTabID) { select(pinnedTab) }
                            .id(pinnedTab.id)
                    }
                }
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .dropDestination(for: String.self) { ids, _ in
                            let dropped = ids.compactMap(browser.tab)
                            dropped.forEach { browser.pin($0) }
                            return !dropped.isEmpty
                        }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: Self.controlSize)
            .onChange(of: selection, initial: true) {
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }

    @ViewBuilder private var navigationControls: some View {
        let canGoBack = tab?.canGoBack == true
        let canGoForward = tab?.canGoForward == true
        if canGoBack || canGoForward {
            HStack(spacing: 0) {
                if canGoBack {
                    iconButton("Back", symbol: "chevron.backward") { browser.perform(.browserBack) }
                        .help("Back (⌘[)")
                }
                if canGoBack, canGoForward { actionDivider }
                if canGoForward {
                    iconButton("Forward", symbol: "chevron.forward") { browser.perform(.browserForward) }
                        .help("Forward (⌘])")
                }
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
        }
    }

    private func trailingActions(tabs: [BrowserTab]) -> some View {
        HStack(spacing: 0) {
            shareMenu
            actionDivider
            iconButton("New Tab", symbol: "plus") {
                if let key = browser.sessionKey { browser.open(nil, in: key) }
            }
            .disabled(browser.sessionKey == nil)
            .help("New Tab (⌘T)")
            .dropDestination(for: String.self, action: dropIntoSession)
            actionDivider
            overviewMenu(tabs: tabs)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .fixedSize()
    }

    private var actionDivider: some View {
        Hairline(axis: .vertical)
            .frame(height: 18)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var shareMenu: some View {
        Menu {
            if let url = tab?.url {
                ShareLink(item: url).help("Share this page")
                BrowserLinkActions(browser: browser, url: url)
            }
        } label: {
            controlIcon("square.and.arrow.up")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Share")
        .disabled(tab?.url == nil)
        .help("Share or open in your default browser")
    }

    private func overviewMenu(tabs: [BrowserTab]) -> some View {
        Menu {
            ForEach(tabs) { tab in
                Button { select(tab) } label: {
                    Label {
                        Text(tab.displayTitle)
                    } icon: {
                        if let favicon = tab.favicon {
                            Image(nsImage: favicon)
                        } else {
                            Image(systemName: "globe")
                        }
                    }
                }
                .help(tab.displayTitle)
            }
            if let key = browser.sessionKey {
                BrowserAgentAccessButton(browser: browser, key: key)
            }
        } label: {
            controlIcon("square.on.square")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Tab Overview")
        .disabled(tabs.isEmpty)
        .help("Show all tabs")
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlIcon(symbol) }
            .accessibilityLabel(title)
    }

    private func controlIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .frame(width: Self.controlSize, height: Self.controlSize)
            .contentShape(.rect)
            .accessibilityHidden(true)
    }

    private func select(_ target: BrowserTab) {
        guard let key = browser.sessionKey else { return }

        if target === tab {
            if let webView = target.loadedWebView { webView.window?.makeFirstResponder(webView) }
        } else {
            target.needsPageFocus = target.url != nil
            browser.select(target, in: key)
        }
    }

    private func dropIntoSession(_ ids: [String], at _: CGPoint) -> Bool {
        guard let key = browser.sessionKey else { return false }

        let dropped = ids.compactMap(browser.tab)
        dropped.forEach { browser.unpin($0, into: key) }
        return !dropped.isEmpty
    }
}

private struct BrowserSessionTabs: View {
    private static let minimumTabWidth: CGFloat = 52
    static let minimumActiveWidth: CGFloat = 120
    static let maximumTabWidth: CGFloat = 220
    static let editingWidth: CGFloat = 360
    private static let minimumTitleWidth: CGFloat = 120
    private static let capsuleInset: CGFloat = 3
    private static let dropWidth: CGFloat = 6
    private static let fadeWidth: CGFloat = 16

    let browser: BrowserModel
    let tabs: [BrowserTab]
    let selection: BrowserTab?
    let isCompact: Bool
    @Binding var editingTabID: UUID?
    let select: (BrowserTab) -> Void
    let dropAtEnd: ([String], CGPoint) -> Bool
    @State private var stripWidth = 0.0
    @State private var frozenTabWidth: CGFloat?
    @State private var hasTrailingOverflow = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let inactiveCount = CGFloat(tabs.count - (selection == nil ? 0 : 1))
        let maximumWidth = inactiveCount * Self.maximumTabWidth + (selection == nil ? 0 : isEditing ? Self.editingWidth : Self.maximumTabWidth) + 2 * Self.capsuleInset
        Color.clear
            .frame(minWidth: (selection == nil ? Self.minimumTabWidth : Self.minimumActiveWidth) + 2 * Self.capsuleInset, maxWidth: maximumWidth)
            .frame(height: BrowserHeader.controlSize + 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
            .onHover { if !$0 { frozenTabWidth = nil } }
            .onChange(of: tabs.count) { old, new in
                guard new < old, !isEditing, selection != nil else {
                    frozenTabWidth = nil
                    return
                }

                frozenTabWidth = widths(width: max(0, stripWidth - 2 * Self.capsuleInset), count: old).inactive
            }
            .animation(.easeInOut(duration: 0.16), value: isEditing)
            .animation(frozenTabWidth == nil ? .easeInOut(duration: 0.16) : nil, value: tabs.count)
            .overlay {
                tabStrip(width: max(0, stripWidth - 2 * Self.capsuleInset))
            }
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: Self.dropWidth)
                    .contentShape(.rect)
                    .dropDestination(for: String.self, action: dropAtEnd)
            }
            .clipShape(.capsule)
            .background {
                if selection != nil {
                    Capsule().fill(theme.foreground.opacity(0.10))
                }
            }
    }

    private var isEditing: Bool {
        selection != nil && editingTabID == selection?.id
    }

    private func widths(width: CGFloat, count: Int) -> (active: CGFloat, inactive: CGFloat) {
        guard selection != nil else { return (0, min(Self.maximumTabWidth, max(Self.minimumTabWidth, width / CGFloat(max(1, count))))) }

        let inactiveCount = CGFloat(count - 1)
        if let frozenTabWidth, !isEditing { return (frozenTabWidth, frozenTabWidth) }

        let equal = width / CGFloat(count)
        let active = min(Self.maximumTabWidth, max(Self.minimumActiveWidth, equal))
        let inactive = min(Self.maximumTabWidth, max(Self.minimumTabWidth, (width - active) / max(1, inactiveCount)))
        guard isEditing else { return (active, inactive) }

        let editing = max(active, min(Self.editingWidth, width - inactiveCount * Self.minimumTabWidth))
        return (editing, min(Self.maximumTabWidth, max(Self.minimumTabWidth, (width - editing) / max(1, inactiveCount))))
    }

    private func tabStrip(width: CGFloat) -> some View {
        let selectedID = selection?.id
        let (activeWidth, inactiveWidth) = widths(width: width, count: tabs.count)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(tabs.enumerated(), id: \.element.id) { index, tab in
                        let isSelected = tab === selection
                        BrowserHeaderTab(browser: browser, tab: tab, isPinned: false, isSelected: isSelected, isCompact: isCompact, showsTitle: inactiveWidth >= Self.minimumTitleWidth, editingTabID: $editingTabID) { select(tab) }
                            .frame(width: isSelected ? activeWidth : inactiveWidth)
                            .overlay(alignment: .leading) {
                                if index > 0, !isSelected, tabs[index - 1] !== selection {
                                    Hairline(axis: .vertical)
                                        .frame(height: 20)
                                        .allowsHitTesting(false)
                                }
                            }
                            .id(tab.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(width: width, height: BrowserHeader.controlSize - 2)
            .clipped()
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxX < geometry.contentSize.width - 1
            } action: { _, hasOverflow in
                hasTrailingOverflow = hasOverflow
            }
            .mask {
                if hasTrailingOverflow {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Self.fadeWidth)
                    }
                } else {
                    Rectangle()
                }
            }
            .onChange(of: selectedID, initial: true) {
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
            .onChange(of: width) {
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
            .padding(Self.capsuleInset)
        }
    }
}

private struct BrowserAgentAccessButton: View {
    let browser: BrowserModel
    let key: String

    var body: some View {
        switch browser.access.decisions[key] {
        case .denied:
            Button("Allow Agent Access") { browser.setAgentAccess(.allowed, for: key) }

        case .allowed:
            Button("Stop Agent Access") { browser.setAgentAccess(.denied, for: key) }

        case nil:
            if browser.tabs(in: key).contains(where: \.isDrivenByAgent) {
                Button("Stop Agent Access") { browser.setAgentAccess(.denied, for: key) }
            }
        }
    }
}

private struct BrowserAgentBadge: View {
    static let width: CGFloat = 22

    let browser: BrowserModel
    let key: String

    var body: some View {
        Menu {
            BrowserAgentAccessButton(browser: browser, key: key)
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: Self.width, height: 18)
                .background(.tint.opacity(0.2), in: .capsule)
                .accessibilityLabel("Agent")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("An agent can control this tab. Click to stop agent access.")
    }
}

private struct BrowserCloseButton: View {
    let browser: BrowserModel
    let tab: BrowserTab

    var body: some View {
        if let key = browser.sessionKey {
            Button { browser.close(tab, in: key) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(.circle)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close Tab")
            .help("Close Tab")
            .padding(.leading, 8)
        }
    }
}

private struct BrowserHeaderTab: View {
    let browser: BrowserModel
    let tab: BrowserTab
    let isPinned: Bool
    let isSelected: Bool
    var isCompact = false
    var showsTitle = true
    @Binding var editingTabID: UUID?
    let select: () -> Void
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if isPinned, !isSelected {
                pinnedButton
            } else if isPinned {
                BrowserAddressField(browser: browser, tab: tab, isMerged: true, isCompact: isCompact, onEditingChange: reportEditing)
                    .frame(height: BrowserHeader.controlSize)
            } else if isSelected {
                BrowserAddressField(browser: browser, tab: tab, isMerged: true, isCompact: isCompact, showsClose: true, onEditingChange: reportEditing)
                    .frame(height: BrowserHeader.controlSize - 2)
            } else {
                sessionButton
                    .onHover { isHovering = $0 }
            }
        }
        .help(tab.displayTitle)
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self, action: drop)
        .contextMenu {
            if let key = browser.sessionKey {
                if isPinned {
                    Button("Unpin Tab") { browser.unpin(tab, into: key) }
                    if tab.isLocked {
                        Button("Unlock") { browser.unlock(tab) }
                    } else {
                        Button("Lock to Page") { browser.lock(tab) }
                            .disabled(tab.url == nil)
                    }
                } else {
                    Button("Pin Tab") { browser.pin(tab) }
                }
                if let url = tab.url { BrowserLinkActions(browser: browser, url: url) }
                BrowserAgentAccessButton(browser: browser, key: key)
                Divider()
                Button("Close Tab") { browser.close(tab, in: key) }
            }
        }
    }

    @ViewBuilder private var lockMarker: some View {
        if tab.isLocked {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.foreground)
                .accessibilityLabel("Locked to page")
        }
    }

    private var pinnedButton: some View {
        Button(action: select) {
            BrowserFavicon(tab: tab, fallback: tab.displayTitle.first.map(String.init))
                .frame(width: BrowserHeader.controlSize, height: BrowserHeader.controlSize)
                .overlay(alignment: .bottomTrailing) { lockMarker.padding(6) }
                .contentShape(.circle)
        }
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background {
            if isSelected {
                Circle()
                    .fill(theme.foreground.opacity(0.18))
                    .strokeBorder(theme.foreground.opacity(0.22), lineWidth: 0.5)
                    .padding(3)
            }
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private var isHovered: Bool {
        isHovering || Snapshot.forcedHover.contains(tab.displayTitle)
    }

    private var sessionButton: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                BrowserFavicon(tab: tab, fallback: nil)
                if showsTitle {
                    Text(tab.displayTitle)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, showsTitle ? 28 : 0)
            .padding(.trailing, !showsTitle && tab.isDrivenByAgent ? BrowserAgentBadge.width + 4 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: BrowserHeader.controlSize - 2)
            .background(theme.foreground.opacity(isHovered ? 0.10 : 0), in: .capsule)
            .contentShape(.capsule)
        }
        .font(.system(size: 13, weight: .medium))
        .accessibilityLabel(tab.displayTitle)
        .overlay(alignment: .leading) {
            if isHovered { BrowserCloseButton(browser: browser, tab: tab) }
        }
        .overlay(alignment: .trailing) {
            if tab.isDrivenByAgent, let key = browser.sessionKey { BrowserAgentBadge(browser: browser, key: key).padding(.trailing, 4) }
        }
    }

    private func reportEditing(_ isEditing: Bool) {
        if isEditing {
            editingTabID = tab.id
        } else if editingTabID == tab.id {
            editingTabID = nil
        }
    }

    private func drop(_ ids: [String], at _: CGPoint) -> Bool {
        guard let key = browser.sessionKey else { return false }

        let siblings = isPinned ? browser.pinned : browser.tabs(in: key)
        let index = siblings.firstIndex { $0 === tab }
        let dropped = ids.compactMap(browser.tab)
        for item in dropped where item !== tab {
            if isPinned { browser.pin(item, at: index) } else { browser.unpin(item, into: key, at: index) }
        }
        return !dropped.isEmpty
    }
}

private struct BrowserAddressField: View {
    private static let placeholder = "Search or enter address"

    let browser: BrowserModel
    let tab: BrowserTab?
    let isMerged: Bool
    let isCompact: Bool
    var showsClose = false
    var onEditingChange: (Bool) -> Void = { _ in }
    @State private var address = ""
    @State private var isEditing = false
    @State private var selection: TextSelection?
    @Environment(\.ghosttyTheme) private var theme
    @FocusState private var isFocused: Bool
    @AppStorage(BrowserModel.searchKey) private var search = BrowserSearch.duckDuckGo
    @AppStorage(BrowserModel.developerToolsKey) private var developerTools = true

    var body: some View {
        let showsPageActions = (isMerged || isCompact) && tab?.url != nil
        let showsAgentBadge = isMerged && tab?.isDrivenByAgent == true && browser.sessionKey != nil
        let accessoryWidth: CGFloat = (showsPageActions ? 38 : 24) + (showsAgentBadge ? BrowserAgentBadge.width + 3 : 0)
        ZStack {
            HStack(spacing: 5) {
                addressIcon
                TextField(Self.placeholder, text: $address, selection: $selection)
                    .textFieldStyle(.plain)
                    .textContentType(.URL)
                    .focused($isFocused)
                    .onSubmit(go)
                    .onExitCommand {
                        finishEditing()
                        if let webView = tab?.loadedWebView { webView.window?.makeFirstResponder(webView) }
                    }
            }
            .padding(.leading, 9)
            .padding(.trailing, accessoryWidth)
            .opacity(isEditing ? 1 : 0)
            .allowsHitTesting(isEditing)
            .accessibilityHidden(!isEditing)

            if !isEditing {
                Button(action: beginEditing) {
                    HStack(spacing: 5) {
                        addressIcon
                        Text(displayAddress)
                            .lineLimit(1)
                    }
                    .padding(.leading, isMerged ? 30 : accessoryWidth)
                    .padding(.trailing, accessoryWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                }
                .accessibilityHint("Edit address")
                .accessibilityAddTraits(isMerged ? .isSelected : [])
                .help("Edit address (⌘L)")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            HStack(spacing: 3) {
                if showsAgentBadge, let key = browser.sessionKey { BrowserAgentBadge(browser: browser, key: key) }
                if showsPageActions, let url = tab?.url {
                    Menu {
                        if isCompact {
                            if tab?.canGoBack == true {
                                Button("Back", systemImage: "chevron.backward") { browser.perform(.browserBack) }
                                    .help("Back (⌘[)")
                            }
                            if tab?.canGoForward == true {
                                Button("Forward", systemImage: "chevron.forward") { browser.perform(.browserForward) }
                                    .help("Forward (⌘])")
                            }
                            if tab?.canGoBack == true || tab?.canGoForward == true { Divider() }
                        }
                        ShareLink(item: url).help("Share this page")
                        BrowserLinkActions(browser: browser, url: url)
                        if developerTools, tab?.canShowInspector == true {
                            let action = AppAction.showWebInspector
                            Button(action.title, systemImage: action.symbol) { browser.perform(action) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 14, height: 22)
                            .contentShape(.rect)
                            .accessibilityHidden(true)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Page Actions")
                    .help("Page Actions")
                }
                reloadButton
                    .labelStyle(.iconOnly)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, 5)
        }
        .background {
            if isMerged {
                Capsule()
                    .fill(theme.foreground.opacity(0.05))
                    .strokeBorder(theme.foreground.opacity(0.14), lineWidth: 0.5)
            }
            if let tab, tab.isLoading {
                BrowserLoadProgress(progress: tab.progress, opacity: 0.2)
            }
        }
        .overlay(alignment: .leading) {
            if showsClose, !isEditing, let tab { BrowserCloseButton(browser: browser, tab: tab) }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .onChange(of: tab?.id, initial: true) {
            finishEditing()
            if let tab, tab.url == nil { beginEditing() }
        }
        .onChange(of: browser.addressFocusRequests) {
            if isEditing { selectAddress() } else { beginEditing() }
        }
        .onChange(of: isEditing) { onEditingChange(isEditing) }
        .onDisappear { onEditingChange(false) }
        .onChange(of: isFocused) {
            if isFocused { selectAddress() } else { isEditing = false }
        }
    }

    @ViewBuilder private var addressIcon: some View {
        if isMerged, let tab, tab.url != nil {
            BrowserFavicon(tab: tab, fallback: nil)
                .overlay(alignment: .bottomTrailing) {
                    if tab.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(theme.foreground)
                            .offset(x: 3, y: 3)
                            .accessibilityLabel("Locked to page")
                    }
                }
        } else if tab?.url == nil || tab?.url?.scheme == "https" {
            Image(systemName: tab?.url == nil ? "magnifyingglass" : "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var displayAddress: String {
        guard let url = tab?.url else { return Self.placeholder }

        if url.isFileURL { return url.lastPathComponent }
        if let scheme = url.scheme, ["https", "http"].contains(scheme) {
            return String(url.absoluteString.dropFirst(scheme.count + 3))
        }
        return url.absoluteString
    }

    private var reloadButton: some View {
        Button {
            if tab?.isLoading == true { tab?.loadedWebView?.stopLoading() } else { tab?.reload() }
        } label: {
            Label(tab?.isLoading == true ? "Stop" : "Reload", systemImage: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                .frame(width: 16, height: 22)
                .contentShape(.rect)
        }
        .disabled(tab?.url == nil)
        .help(tab?.isLoading == true ? "Stop" : "Reload (⌘R)")
    }

    private func beginEditing() {
        guard !isEditing else { return }

        address = tab?.url?.absoluteString ?? ""
        isEditing = true
        Task {
            guard NSApp.keyWindow != nil else { return }

            isFocused = true
        }
    }

    private func selectAddress() {
        selection = TextSelection(range: address.startIndex..<address.endIndex)
    }

    private func finishEditing() {
        isFocused = false
        isEditing = false
    }

    private func go() {
        guard let key = browser.sessionKey, let url = WebAddress.resolve(address, searchTemplate: search.template) else { return }

        if let tab { tab.load(url) } else { browser.open(url, in: key) }
        finishEditing()
        guard let target = browser.selectedTab(in: key) else { return }

        if let webView = target.loadedWebView, let window = webView.window {
            window.makeFirstResponder(webView)
        } else {
            target.needsPageFocus = true
        }
    }
}

private struct BrowserLoadProgress: View {
    let progress: Double
    let opacity: Double

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(opacity))
            .scaleEffect(x: max(progress, 0.05), anchor: .leading)
            .clipShape(.capsule)
            .animation(.easeOut(duration: 0.2), value: progress)
            .allowsHitTesting(false)
    }
}

private struct BrowserFavicon: View {
    let tab: BrowserTab
    let fallback: String?

    var body: some View {
        Group {
            if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if let fallback {
                Text(fallback.uppercased())
                    .font(.caption.weight(.semibold))
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct BrowserLinkActions: View {
    let browser: BrowserModel
    let url: URL

    var body: some View {
        Button("Open in Default Browser") { browser.openOutside(url) }
            .help("Open in Default Browser")
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .help("Copy Link")
    }
}

private struct BrowserDownloadsButton: View {
    let browser: BrowserModel

    var body: some View {
        if let last = browser.downloads.last {
            let active = browser.downloads.filter { !$0.isFinished && !$0.failed }
            Button {
                if let destination = last.destination, last.isFinished { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } label: {
                ZStack {
                    if active.isEmpty {
                        Image(systemName: last.failed ? "exclamationmark.arrow.circlepath" : "arrow.down.circle")
                    } else {
                        ProgressView(value: active.map(\.fraction).reduce(0, +) / Double(active.count))
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                    }
                }
                .frame(width: BrowserHeader.controlSize, height: BrowserHeader.controlSize)
                .contentShape(.circle)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .help(last.failed ? "\(last.name) didn’t download" : last.isFinished ? "Show \(last.name) in Finder" : "Downloading \(last.name) to Downloads")
            .accessibilityLabel("Downloads")
        }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let tab: BrowserTab
    @AppStorage(BrowserModel.appearanceKey) private var appearance = BrowserAppearance.auto

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = tab.webView
        webView.appearance = appearance.appearance
        guard webView.superview !== container else { return }

        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        if tab.needsPageFocus {
            tab.needsPageFocus = false
            DispatchQueue.main.async { [weak webView] in
                guard let webView, webView.superview === container else { return }

                webView.window?.makeFirstResponder(webView)
            }
        }
    }
}
