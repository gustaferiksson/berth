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
            .background(theme.background ?? Color(nsColor: .textBackgroundColor))
            .clipShape(.rect(cornerRadius: CardBorder.radius, style: .continuous))
            .overlay { CardBorder() }
        }
    }
}

private struct BrowserHeader: View {
    static let controlSize: CGFloat = 30
    private static let wideSpacing: CGFloat = 8
    private static let compactSpacing: CGFloat = 6
    private static let compactThreshold: CGFloat = 640

    let browser: BrowserModel
    let tab: BrowserTab?
    @State private var width: CGFloat = 0

    var body: some View {
        let pinned = browser.pinned
        let sessionTabs = browser.sessionKey.map(browser.tabs) ?? []
        let isCompact = width < Self.compactThreshold
        let spacing = isCompact ? Self.compactSpacing : Self.wideSpacing
        let pinnedWidth = min(
            CGFloat(pinned.count) * (Self.controlSize + spacing) - spacing,
            max(Self.controlSize, width * 0.25)
        )

        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                if !isCompact {
                    circleButton("Back", symbol: "chevron.backward") { browser.perform(.browserBack) }
                        .disabled(tab?.canGoBack != true)
                        .help("Back (⌘[)")
                    circleButton("Forward", symbol: "chevron.forward") { browser.perform(.browserForward) }
                        .disabled(tab?.canGoForward != true)
                        .help("Forward (⌘])")
                }
                if !pinned.isEmpty {
                    pinnedTabs(pinned, spacing: spacing)
                        .frame(width: pinnedWidth)
                }
                if !sessionTabs.isEmpty {
                    BrowserSessionTabs(browser: browser, tabs: sessionTabs, selection: tab, select: select, dropAtEnd: dropIntoSession)
                        .layoutPriority(1)
                }
                BrowserAddressField(browser: browser, tab: tab)
                    .layoutPriority(0)
                if !isCompact { shareMenu }
                circleButton("New Tab", symbol: "plus") {
                    if let key = browser.sessionKey { browser.open(nil, in: key) }
                }
                .disabled(browser.sessionKey == nil)
                .help("New Tab (⌘T)")
                .dropDestination(for: String.self, action: dropIntoSession)
                BrowserDownloadsButton(browser: browser)
                overviewMenu(tabs: pinned + sessionTabs, showsPageActions: isCompact)
            }
            .frame(maxWidth: .infinity)
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

    private var shareMenu: some View {
        Menu {
            shareActions
        } label: {
            circleIcon("square.and.arrow.up")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Share")
        .disabled(tab?.url == nil)
        .help("Share or open in your default browser")
    }

    @ViewBuilder private var shareActions: some View {
        if let url = tab?.url {
            ShareLink(item: url)
            BrowserLinkActions(browser: browser, url: url)
        }
    }

    private func overviewMenu(tabs: [BrowserTab], showsPageActions: Bool) -> some View {
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
            }
            if showsPageActions, !tabs.isEmpty {
                Divider()
                shareActions
                Button("Back", systemImage: "chevron.backward") { browser.perform(.browserBack) }
                    .disabled(tab?.canGoBack != true)
                Button("Forward", systemImage: "chevron.forward") { browser.perform(.browserForward) }
                    .disabled(tab?.canGoForward != true)
            }
        } label: {
            circleIcon("square.on.square")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Tab Overview")
        .disabled(tabs.isEmpty)
        .help("Show all tabs")
    }

    private func circleButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleIcon(symbol) }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(title)
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .contentShape(.circle)
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
    private static let minimumTabWidth: CGFloat = 90
    private static let idealTabWidth: CGFloat = 140
    private static let capsuleInset: CGFloat = 3
    private static let dropWidth: CGFloat = 10
    private static let fadeWidth: CGFloat = 16

    let browser: BrowserModel
    let tabs: [BrowserTab]
    let selection: BrowserTab?
    let select: (BrowserTab) -> Void
    let dropAtEnd: ([String], CGPoint) -> Bool
    @State private var hasTrailingOverflow = false

    var body: some View {
        let selectedID = tabs.first { $0 === selection }?.id
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(tabs.enumerated(), id: \.element.id) { index, tab in
                            BrowserHeaderTab(browser: browser, tab: tab, isPinned: false, isSelected: tab === selection) { select(tab) }
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    min(Self.idealTabWidth, max(Self.minimumTabWidth, width / CGFloat(tabs.count)))
                                }
                                .overlay(alignment: .leading) {
                                    if index > 0, tab !== selection, tabs[index - 1] !== selection {
                                        Hairline(axis: .vertical)
                                            .frame(height: 14)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .id(tab.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
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
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in
                    if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
                }
                Color.clear
                    .frame(width: Self.dropWidth)
                    .contentShape(.rect)
                    .dropDestination(for: String.self, action: dropAtEnd)
            }
            .padding(.horizontal, Self.capsuleInset)
            .frame(minWidth: 0, maxWidth: CGFloat(tabs.count) * Self.idealTabWidth + Self.dropWidth + 2 * Self.capsuleInset)
            .frame(height: BrowserHeader.controlSize)
            .clipShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

private struct BrowserHeaderTab: View {
    let browser: BrowserModel
    let tab: BrowserTab
    let isPinned: Bool
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if isPinned {
                pinnedButton
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

    private var sessionButton: some View {
        let key = browser.sessionKey
        let showsClose = key != nil && (isHovering || Snapshot.forcedHover.contains(tab.displayTitle))
        return Button(action: select) {
            HStack(spacing: 5) {
                if !showsClose { BrowserFavicon(tab: tab, fallback: nil) }
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, showsClose ? 22 : 5)
            .padding(.trailing, 5)
            .frame(maxWidth: .infinity)
            .frame(height: BrowserHeader.controlSize)
            .contentShape(.rect)
        }
        .font(.system(size: 12))
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background {
            if isSelected || showsClose {
                Capsule()
                    .fill(theme.foreground.opacity(isSelected ? 0.18 : 0.08))
                    .overlay {
                        if isSelected, tab.isLoading {
                            BrowserLoadProgress(progress: tab.progress, opacity: 0.08)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
            }
        }
        .overlay(alignment: .leading) {
            if showsClose, let key {
                Button { browser.close(tab, in: key) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 20)
                        .contentShape(.rect)
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close Tab")
                .help("Close Tab")
                .padding(.leading, 4)
            }
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
    private static let minimumWidth: CGFloat = 110
    private static let idealWidth: CGFloat = 200
    private static let accessoryThreshold: CGFloat = 160

    let browser: BrowserModel
    let tab: BrowserTab?
    @State private var address = ""
    @State private var isEditing = false
    @State private var selection: TextSelection?
    @State private var showsSearchIcon = false
    @FocusState private var isFocused: Bool
    @AppStorage(BrowserModel.searchKey) private var search = BrowserSearch.duckDuckGo

    var body: some View {
        HStack(spacing: showsSearchIcon ? 6 : 0) {
            if isEditing {
                if showsSearchIcon { searchIcon }
                TextField(Self.placeholder, text: $address, selection: $selection)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .focused($isFocused)
                    .onAppear { isFocused = true }
                    .onSubmit(go)
                    .onExitCommand {
                        finishEditing()
                        if let webView = tab?.loadedWebView { webView.window?.makeFirstResponder(webView) }
                    }
            } else {
                Button(action: editAddress) {
                    HStack(spacing: 6) {
                        if showsSearchIcon { searchIcon }
                        HStack(spacing: 4) {
                            if tab?.url?.scheme == "https" {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            Text(displayAddress)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: BrowserHeader.controlSize)
                    .contentShape(.rect)
                }
                .accessibilityHint("Edit address")
            }
            reloadButton
                .labelStyle(.iconOnly)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(minWidth: Self.minimumWidth, idealWidth: Self.idealWidth, maxWidth: .infinity)
        .frame(height: BrowserHeader.controlSize)
        .background {
            if let tab, tab.isLoading {
                BrowserLoadProgress(progress: tab.progress, opacity: 0.2)
            }
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.accessoryThreshold } action: { showsSearchIcon = $0 }
        .onChange(of: tab?.id, initial: true) {
            if let tab, tab.url == nil { editAddress() } else { finishEditing() }
        }
        .onChange(of: browser.addressFocusRequests, editAddress)
        .onChange(of: isFocused) {
            if isFocused { selectAddress() } else { isEditing = false }
        }
    }

    private var displayAddress: String {
        guard let tab, let url = tab.url else { return Self.placeholder }

        return url.host(percentEncoded: false) ?? tab.displayTitle
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var reloadButton: some View {
        Button {
            if tab?.isLoading == true { tab?.loadedWebView?.stopLoading() } else { tab?.loadedWebView?.reload() }
        } label: {
            Label(tab?.isLoading == true ? "Stop" : "Reload", systemImage: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                .frame(width: 16, height: 22)
                .contentShape(.rect)
        }
        .disabled(tab?.url == nil)
        .help(tab?.isLoading == true ? "Stop" : "Reload (⌘R)")
    }

    private func editAddress() {
        address = tab?.url?.absoluteString ?? ""
        if isFocused { selectAddress() } else { isEditing = true }
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
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
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
