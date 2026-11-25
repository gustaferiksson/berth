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

    var body: some View {
        let pinned = browser.pinned
        let sessionTabs = browser.sessionKey.map(browser.tabs) ?? []
        let selectedSession = sessionTabs.first { $0 === tab }
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
                    HStack(spacing: 2) {
                        if !pinned.isEmpty {
                            pinnedTabs(pinned, spacing: spacing)
                                .frame(width: pinnedWidth)
                            if !sessionTabs.isEmpty {
                                Hairline(axis: .vertical)
                                    .frame(height: 24)
                                    .allowsHitTesting(false)
                            }
                        }
                        if !sessionTabs.isEmpty {
                            BrowserSessionTabs(browser: browser, tabs: sessionTabs, selection: selectedSession, isCompact: isCompact, select: select, dropAtEnd: dropIntoSession)
                        }
                    }
                }
                if selectedSession == nil {
                    BrowserAddressField(browser: browser, tab: tab, isMerged: false, isCompact: isCompact)
                        .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
                        .frame(height: Self.controlSize)
                }
                trailingActions(tabs: pinned + sessionTabs)
                BrowserDownloadsButton(browser: browser)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.16), value: tab?.canGoBack == true)
            .animation(.easeInOut(duration: 0.16), value: tab?.canGoForward == true)
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, spacing)
        .padding(.vertical, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func pinnedTabs(_ pinned: [BrowserTab], spacing: CGFloat) -> some View {
        let selection = pinned.first { $0 === tab }?.id
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: spacing) {
                    ForEach(pinned) { pinnedTab in
                        BrowserHeaderTab(browser: browser, tab: pinnedTab, isPinned: true, isSelected: pinnedTab === tab) { select(pinnedTab) }
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
        let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.94, anchor: .leading))
        if canGoBack || canGoForward {
            HStack(spacing: 0) {
                if canGoBack {
                    iconButton("Back", symbol: "chevron.backward") { browser.perform(.browserBack) }
                        .help("Back (⌘[)")
                        .transition(transition)
                }
                if canGoBack, canGoForward { actionDivider.transition(.opacity) }
                if canGoForward {
                    iconButton("Forward", symbol: "chevron.forward") { browser.perform(.browserForward) }
                        .help("Forward (⌘])")
                        .transition(transition)
                }
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .fixedSize()
            .transition(transition)
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
    private static let minimumActiveWidth: CGFloat = 160
    private static let minimumTitleWidth: CGFloat = 104
    private static let capsuleInset: CGFloat = 3
    private static let dropWidth: CGFloat = 6
    private static let fadeWidth: CGFloat = 16

    let browser: BrowserModel
    let tabs: [BrowserTab]
    let selection: BrowserTab?
    let isCompact: Bool
    let select: (BrowserTab) -> Void
    let dropAtEnd: ([String], CGPoint) -> Bool
    @State private var stripWidth = 0.0
    @State private var hasTrailingOverflow = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let standaloneWidth = CGFloat(tabs.count) * Self.minimumTitleWidth + 2 * Self.capsuleInset
        Color.clear
            .frame(minWidth: 0, maxWidth: selection == nil ? standaloneWidth : .infinity)
            .frame(height: BrowserHeader.controlSize + 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
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
                } else {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
    }

    private func tabStrip(width: CGFloat) -> some View {
        let selectedID = selection?.id
        let activeWidth = selection == nil ? 0 : max(Self.minimumActiveWidth, width / CGFloat(tabs.count))
        let inactiveCount = CGFloat(tabs.count - (selection == nil ? 0 : 1))
        let inactiveWidth = max(Self.minimumTabWidth, (width - activeWidth) / max(1, inactiveCount))
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(tabs.enumerated(), id: \.element.id) { index, tab in
                        let isSelected = tab === selection
                        BrowserHeaderTab(browser: browser, tab: tab, isPinned: false, isSelected: isSelected, isCompact: isCompact, showsTitle: inactiveWidth >= Self.minimumTitleWidth) { select(tab) }
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

private struct BrowserHeaderTab: View {
    let browser: BrowserModel
    let tab: BrowserTab
    let isPinned: Bool
    let isSelected: Bool
    var isCompact = false
    var showsTitle = true
    let select: () -> Void
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if isPinned {
                pinnedButton
            } else if isSelected {
                BrowserAddressField(browser: browser, tab: tab, isMerged: true, isCompact: isCompact)
                    .frame(height: BrowserHeader.controlSize - 2)
                    .overlay(alignment: .leading) {
                        if isHovered { closeButton }
                    }
                    .onHover { isHovering = $0 }
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
                } else {
                    Button("Pin Tab") { browser.pin(tab) }
                }
                if let url = tab.url { BrowserLinkActions(browser: browser, url: url) }
                Divider()
                Button("Close Tab") { browser.close(tab, in: key) }
            }
        }
    }

    private var pinnedButton: some View {
        Button(action: select) {
            BrowserFavicon(tab: tab, fallback: tab.displayTitle.first.map(String.init))
                .frame(width: BrowserHeader.controlSize, height: BrowserHeader.controlSize)
                .contentShape(.circle)
        }
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background {
            if isSelected {
                Circle()
                    .fill(theme.foreground.opacity(0.14))
                    .padding(3)
            }
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }

    private var isHovered: Bool {
        isHovering || Snapshot.forcedHover.contains(tab.displayTitle)
    }

    @ViewBuilder private var closeButton: some View {
        if let key = browser.sessionKey {
            Button { browser.close(tab, in: key) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 22)
                    .contentShape(.rect)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close Tab")
            .help("Close Tab")
            .padding(.leading, 3)
        }
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
            .padding(.horizontal, showsTitle ? 22 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: BrowserHeader.controlSize - 2)
            .background(theme.foreground.opacity(isHovered ? 0.10 : 0), in: .capsule)
            .contentShape(.capsule)
        }
        .font(.system(size: 13, weight: .medium))
        .accessibilityLabel(tab.displayTitle)
        .overlay(alignment: .leading) {
            if isHovered { closeButton }
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
    @State private var address = ""
    @State private var isEditing = false
    @State private var selection: TextSelection?
    @Environment(\.ghosttyTheme) private var theme
    @FocusState private var isFocused: Bool
    @AppStorage(BrowserModel.searchKey) private var search = BrowserSearch.duckDuckGo

    var body: some View {
        let showsPageActions = (isMerged || isCompact) && tab?.url != nil
        let accessoryWidth: CGFloat = showsPageActions ? 38 : 24
        ZStack {
            HStack(spacing: 5) {
                addressIcon
                TextField(Self.placeholder, text: $address, selection: $selection)
                    .textFieldStyle(.plain)
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
                    .padding(.leading, isMerged ? 24 : accessoryWidth)
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
        .glassEffect(.regular.interactive(), in: .capsule)
        .onChange(of: tab?.id, initial: true) {
            finishEditing()
            if let tab, tab.url == nil { beginEditing() }
        }
        .onChange(of: browser.addressFocusRequests) {
            if isEditing { selectAddress() } else { beginEditing() }
        }
        .onChange(of: isFocused) {
            if isFocused { selectAddress() } else { isEditing = false }
        }
    }

    @ViewBuilder private var addressIcon: some View {
        if isMerged, let tab, tab.url != nil {
            BrowserFavicon(tab: tab, fallback: nil)
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
        isFocused = true
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

        let target = tab ?? browser.open(url, in: key)
        tab?.load(url)
        finishEditing()
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

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context _: Context) {
        let webView = tab.webView
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
