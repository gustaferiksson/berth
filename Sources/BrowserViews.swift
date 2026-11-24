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
            BrowserAddressBar(browser: browser, tab: tab)
            Divider()
                .overlay(alignment: .leading) {
                    if let tab, tab.isLoading {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .scaleEffect(x: max(tab.progress, 0.05), anchor: .leading)
                            .animation(.easeOut(duration: 0.2), value: tab.progress)
                    }
                }
            if let tab, tab.url != nil {
                BrowserWebView(tab: tab)
            } else {
                ContentUnavailableView {
                    Label("New Tab", systemImage: "globe")
                } description: {
                    Text("Type an address, or words to search with \(BrowserSearch(rawValue: UserDefaults.standard.string(forKey: BrowserModel.searchKey) ?? "")?.title ?? BrowserSearch.duckDuckGo.title)")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.background ?? Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: CardBorder.radius, style: .continuous))
        .overlay { CardBorder() }
    }
}

private struct BrowserAddressBar: View {
    let browser: BrowserModel
    let tab: BrowserTab?
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @AppStorage(BrowserModel.searchKey) private var search = BrowserSearch.duckDuckGo
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let url = tab?.url
        HStack(spacing: 2) {
            Button("Back", systemImage: "chevron.backward") { tab?.loadedWebView?.goBack() }
                .disabled(tab?.canGoBack != true)
                .help("Back (⌘[)")
            Button("Forward", systemImage: "chevron.forward") { tab?.loadedWebView?.goForward() }
                .disabled(tab?.canGoForward != true)
                .help("Forward (⌘])")
            if tab?.isLoading == true {
                Button("Stop", systemImage: "xmark") { tab?.loadedWebView?.stopLoading() }
                    .help("Stop")
            } else {
                Button("Reload", systemImage: "arrow.clockwise") { tab?.loadedWebView?.reload() }
                    .disabled(url == nil)
                    .help("Reload (⌘R)")
            }
            HStack(spacing: 6) {
                Image(systemName: url?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search or enter address", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(go)
                    .onExitCommand {
                        text = url?.absoluteString ?? ""
                        isFocused = false
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.foreground.opacity(isFocused ? 0.1 : 0.06), in: .rect(cornerRadius: 6))
            .overlay {
                if isFocused { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6)) }
            }
            .padding(.horizontal, 4)
            BrowserDownloadsButton(browser: browser)
            Menu("Share", systemImage: "square.and.arrow.up") {
                if let url {
                    ShareLink(item: url)
                    Button("Open in Default Browser") { browser.openOutside(url) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(url == nil)
            .help("Share or open in your default browser")
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(height: 34)
        .onChange(of: url, initial: true) { if !isFocused { text = url?.absoluteString ?? "" } }
        .onChange(of: tab?.id) { text = tab?.url?.absoluteString ?? "" }
        .onAppear { if tab?.url == nil { isFocused = true } }
        .onChange(of: browser.addressFocusRequests) {
            isFocused = true
            DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil) }
        }
    }

    private func go() {
        guard let key = browser.sessionKey, let url = WebAddress.resolve(text, searchTemplate: search.template) else { return }

        if let tab {
            tab.load(url)
        } else {
            browser.open(url, in: key)
        }
        isFocused = false
        tab?.loadedWebView.map { _ = $0.window?.makeFirstResponder($0) }
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
                .frame(width: 18, height: 18)
            }
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
    }
}

struct BrowserTabList: View {
    @Environment(Store.self) private var store
    @State private var isPinnedExpanded = true
    @State private var isSessionExpanded = true

    var body: some View {
        let browser = store.browser
        let key = browser.sessionKey
        let sessionTabs = key.map(browser.tabs) ?? []
        List {
            SidebarSection(isExpanded: $isPinnedExpanded) {
                ForEach(browser.pinned) { tab in
                    BrowserTabRow(tab: tab, isPinned: true)
                }
            } header: { expansion in
                SidebarSectionHeader<EmptyView, EmptyView>(title: "Pinned", help: "Tabs shown in every session", count: browser.pinned.count, isExpanded: expansion, accessory: nil, replacementTitle: nil)
                    .dropDestination(for: String.self) { ids, _ in
                        ids.compactMap(browser.tab).forEach { browser.pin($0) }
                        return true
                    }
            }
            SidebarSection(isExpanded: $isSessionExpanded) {
                ForEach(sessionTabs) { tab in
                    BrowserTabRow(tab: tab, isPinned: false)
                }
            } header: { expansion in
                SidebarSectionHeader(title: "This session", help: "Tabs that belong to this session", count: sessionTabs.count, isExpanded: expansion) {
                    Button("New Tab", systemImage: "plus") { if let key { browser.open(nil, in: key) } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("New Tab (⌘T)")
                }
                .dropDestination(for: String.self) { ids, _ in
                    guard let key else { return false }

                    ids.compactMap(browser.tab).forEach { browser.unpin($0, into: key) }
                    return true
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct BrowserTabRow: View {
    let tab: BrowserTab
    let isPinned: Bool
    @State private var isHovering = false
    @Environment(Store.self) private var store

    var body: some View {
        let browser = store.browser
        let key = browser.sessionKey
        let isSelected = browser.shownTab === tab
        let isHighlighted = isHovering || Snapshot.forcedHover.contains(tab.displayTitle)
        HStack(spacing: 8) {
            Group {
                if let favicon = tab.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .padding(.horizontal, SidebarRowLayout.horizontalInset)
        .contentShape(.rect)
        .onTapGesture {
            guard let key else { return }

            browser.select(tab, in: key)
            store.showBrowserPane()
        }
        .onHover { isHovering = $0 }
        // swiftlint:disable:next negative_padding - widens the row's hit area back to the list edges, the close button is an overlay added after
        .padding(.horizontal, -SidebarRowLayout.horizontalInset)
        .overlay(alignment: .trailing) {
            if isHighlighted || isSelected, let key {
                Button(isPinned ? "Unpin Tab" : "Close Tab", systemImage: isPinned ? "pin.slash" : "xmark") {
                    if isPinned { browser.unpin(tab, into: key) } else { browser.close(tab, in: key) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 16, height: 16)
                .contentShape(.rect)
                .help(isPinned ? "Unpin tab" : "Close tab")
            }
        }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let key else { return false }

            let siblings = isPinned ? browser.pinned : browser.tabs(in: key)
            let index = siblings.firstIndex { $0 === tab }
            for dropped in ids.compactMap(browser.tab) where dropped !== tab {
                if isPinned { browser.pin(dropped, at: index) } else { browser.unpin(dropped, into: key, at: index) }
            }
            return true
        }
        .contextMenu {
            if let key {
                if isPinned {
                    Button("Unpin Tab") { browser.unpin(tab, into: key) }
                } else {
                    Button("Pin Tab") { browser.pin(tab) }
                }
                if let url = tab.url {
                    Button("Open in Default Browser") { browser.openOutside(url) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Divider()
                Button("Close Tab") { browser.close(tab, in: key) }
            }
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
        .listRowBackground(RowFill(opacity: isSelected ? 0.18 : isHighlighted ? 0.06 : 0, color: isSelected ? .accentColor : .primary, cornerRadius: 6, verticalInset: 1))
        .listRowSeparator(.hidden)
    }
}
