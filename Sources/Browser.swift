import AppKit
import BerthCore
import WebKit

enum BrowserSearch: String, CaseIterable {
    case duckDuckGo, google, bing, kagi, startpage

    var title: String {
        [.duckDuckGo: "DuckDuckGo", .google: "Google", .bing: "Bing", .kagi: "Kagi", .startpage: "Startpage"][self] ?? rawValue
    }

    var template: String {
        let templates: [Self: String] = [
            .duckDuckGo: "https://duckduckgo.com/?q=%s",
            .google: "https://www.google.com/search?q=%s",
            .bing: "https://www.bing.com/search?q=%s",
            .kagi: "https://kagi.com/search?q=%s",
            .startpage: "https://www.startpage.com/do/search?q=%s",
        ]
        return templates[self] ?? templates[.duckDuckGo] ?? ""
    }
}

enum BrowserLinkTarget: String {
    case defaultBrowser, berth
}

@Observable
final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    var url: URL?
    var title: String
    var favicon: NSImage?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored var needsPageFocus = false
    @ObservationIgnored private(set) var loadedWebView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private unowned let browser: BrowserModel

    init(url: URL?, title: String = "", browser: BrowserModel) {
        self.url = url
        self.title = title
        self.browser = browser
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host(percentEncoded: false) ?? url?.lastPathComponent ?? "New Tab"
    }

    var webView: WKWebView {
        if let loadedWebView { return loadedWebView }

        let view = WKWebView(frame: .zero, configuration: browser.configuration())
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = true
        observations = [
            view.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { if let title = view.title, !title.isEmpty { self?.title = title } } },
            view.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { if let url = view.url { self?.url = url } } },
            view.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
            view.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            view.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
        loadedWebView = view
        if let url, browser.mayLoad { view.load(URLRequest(url: url)) }
        return view
    }

    func load(_ url: URL) {
        self.url = url
        guard browser.mayLoad else { return }

        webView.load(URLRequest(url: url))
    }

    func unload() {
        observations = []
        loadedWebView?.stopLoading()
        loadedWebView?.removeFromSuperview()
        loadedWebView = nil
        needsPageFocus = false
        isLoading = false
        progress = 0
    }

    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload { return (.download, preferences) }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return (.allow, preferences) }

        if browser.isSnapshot, !["file", "about", "data", "blob"].contains(scheme) {
            print("snapshot browser blocked \(url.absoluteString)")
            return (.cancel, preferences)
        }
        if ["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme) { return (.allow, preferences) }

        if action.navigationType == .linkActivated { browser.openOutside(url) }
        return (.cancel, preferences)
    }

    func webView(_: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload) {
        browser.track(download)
    }

    func webView(_: WKWebView, navigationResponse _: WKNavigationResponse, didBecome download: WKDownload) {
        browser.track(download)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        browser.save()
        Task { favicon = await browser.favicon(of: webView) ?? favicon }
    }

    func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { browser.openFromPage(url, opener: self) }
        return nil
    }
}

@Observable
final class BrowserDownload: Identifiable {
    let id = UUID()
    var name = ""
    var destination: URL?
    var fraction = 0.0
    var isFinished = false
    var failed = false
}

@Observable
final class BrowserModel: NSObject, WKDownloadDelegate {
    static let searchKey = "browserSearchEngine"
    static let persistentDataKey = "browserKeepsWebsiteData"
    static let linksKey = "conversationLinksOpenIn"
    static let githubLinksKey = "githubLinksOpenInBerth"
    private static let pinnedKey = "browserPinnedTabs"
    private static let sessionTabsKey = "browserSessionTabs"
    private static let ephemeralStore = WKWebsiteDataStore.nonPersistent()
    private static let faviconSession = URLSession(configuration: .ephemeral)

    private struct Saved: Codable {
        let url: URL?
        let title: String
    }

    var pinned: [BrowserTab] = []
    var sessionTabs: [String: [BrowserTab]] = [:]
    var selectedIDs: [String: BrowserTab.ID] = [:]
    var downloads: [BrowserDownload] = []
    var addressFocusRequests = 0
    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var snapshotRules: WKContentRuleList?
    @ObservationIgnored private var downloadsByTask: [ObjectIdentifier: BrowserDownload] = [:]
    @ObservationIgnored private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(store: Store) {
        self.store = store
    }

    var isSnapshot: Bool {
        Snapshot.output != nil
    }

    var sessionKey: String? {
        store.sessionTab.map(Self.key)
    }

    static func key(of tab: Tab) -> String {
        tab.sessionID ?? tab.id.uuidString
    }

    func tabs(in key: String) -> [BrowserTab] {
        sessionTabs[key] ?? []
    }

    func selectedTab(in key: String?) -> BrowserTab? {
        guard let key else { return nil }

        let all = pinned + tabs(in: key)
        return all.first { $0.id == selectedIDs[key] } ?? tabs(in: key).last ?? pinned.first
    }

    var shownTab: BrowserTab? {
        selectedTab(in: sessionKey)
    }

    var mayLoad: Bool {
        !isSnapshot || snapshotRules != nil
    }

    func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = !isSnapshot && UserDefaults.standard.bool(forKey: Self.persistentDataKey) ? .default() : Self.ephemeralStore
        if let snapshotRules { configuration.userContentController.add(snapshotRules) }
        return configuration
    }

    /// Snapshots load local fixture pages only, so every subresource that isn't file, data or about is blocked too.
    func prepareSnapshotRules() async {
        let rules: [[String: [String: String]]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]] + ["^file:", "^data:", "^about:"].map { ["trigger": ["url-filter": $0], "action": ["type": "ignore-previous-rules"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return }

        snapshotRules = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "berth-browser-snapshot", encodedContentRuleList: String(decoding: data, as: UTF8.self))
        print("snapshot browser rules \(snapshotRules == nil ? "failed, nothing loads" : "compiled")")
    }

    @discardableResult
    func open(_ url: URL?, in key: String, title: String = "", selects: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, title: title, browser: self)
        sessionTabs[key, default: []].append(tab)
        if selects { selectedIDs[key] = tab.id }
        if url == nil { addressFocusRequests += 1 }
        save()
        return tab
    }

    func openFromPage(_ url: URL, opener: BrowserTab) {
        let key = sessionTabs.first { $0.value.contains { $0 === opener } }?.key ?? sessionKey
        guard let key else { return }

        open(url, in: key)
    }

    func select(_ tab: BrowserTab, in key: String) {
        selectedIDs[key] = tab.id
    }

    func selectTab(number: Int? = nil, offset: Int = 0) {
        guard let key = sessionKey, let current = shownTab else { return }

        let candidates = pinned + tabs(in: key)
        let index: Int
        if let number {
            index = number == 9 ? candidates.count - 1 : number - 1
        } else {
            guard let currentIndex = candidates.firstIndex(where: { $0 === current }) else { return }

            index = (currentIndex + offset + candidates.count) % candidates.count
        }
        guard candidates.indices.contains(index), candidates[index] !== current else { return }

        let target = candidates[index]
        target.needsPageFocus = target.url != nil
        select(target, in: key)
    }

    func close(_ tab: BrowserTab, in key: String) {
        let siblings = pinned.contains { $0 === tab } ? pinned : tabs(in: key)
        let index = siblings.firstIndex { $0 === tab } ?? 0
        tab.unload()
        pinned.removeAll { $0 === tab }
        sessionTabs[key]?.removeAll { $0 === tab }
        if selectedIDs[key] == tab.id {
            let remaining = siblings.filter { $0 !== tab }
            selectedIDs[key] = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        save()
    }

    func pin(_ tab: BrowserTab, at index: Int? = nil) {
        for key in sessionTabs.keys { sessionTabs[key]?.removeAll { $0 === tab } }
        pinned.removeAll { $0 === tab }
        pinned.insert(tab, at: min(index ?? pinned.count, pinned.count))
        save()
    }

    func unpin(_ tab: BrowserTab, into key: String, at index: Int? = nil) {
        pinned.removeAll { $0 === tab }
        sessionTabs[key]?.removeAll { $0 === tab }
        let count = tabs(in: key).count
        sessionTabs[key, default: []].insert(tab, at: min(index ?? count, count))
        save()
    }

    func tab(withID id: String) -> BrowserTab? {
        (pinned + sessionTabs.values.flatMap(\.self)).first { $0.id.uuidString == id }
    }

    func discard(_ key: String) {
        for tab in tabs(in: key) { tab.unload() }
        sessionTabs[key] = nil
        selectedIDs[key] = nil
        save()
    }

    func rekey(from old: String, to new: String) {
        guard old != new, let moved = sessionTabs.removeValue(forKey: old) else { return }

        sessionTabs[new, default: []] += moved
        selectedIDs[new] = selectedIDs.removeValue(forKey: old) ?? selectedIDs[new]
        save()
    }

    func release(_ key: String) {
        for tab in tabs(in: key) { tab.unload() }
    }

    func focusAddress() {
        guard let key = sessionKey else { return }

        if selectedTab(in: key) == nil {
            open(nil, in: key)
        } else {
            addressFocusRequests += 1
        }
    }

    func perform(_ action: AppAction) {
        if action == .openLocation { return focusAddress() }
        guard let key = sessionKey else { return }

        if action == .newBrowserTab {
            open(nil, in: key)
            return
        }
        guard let tab = shownTab else { return }

        if action == .closeBrowserTab { return close(tab, in: key) }
        if action == .reloadPage { tab.loadedWebView?.reload() }
        if action == .browserBack { tab.loadedWebView?.goBack() }
        if action == .browserForward { tab.loadedWebView?.goForward() }
    }

    func openOutside(_ url: URL) {
        guard !isSnapshot else {
            print("snapshot openURL \(url.absoluteString)")
            return
        }

        NSWorkspace.shared.open(url)
    }

    func save() {
        guard store.persistsTabs else { return }

        let encode = { (tabs: [BrowserTab]) in tabs.compactMap { tab in tab.url.map { Saved(url: $0, title: tab.title) } } }
        UserDefaults.standard.set(try? JSONEncoder().encode(encode(pinned)), forKey: Self.pinnedKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(sessionTabs.filter { !$0.value.isEmpty }.mapValues(encode)), forKey: Self.sessionTabsKey)
    }

    func restore() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.pinnedKey), let saved = try? decoder.decode([Saved].self, from: data) {
            pinned = saved.map { BrowserTab(url: $0.url, title: $0.title, browser: self) }
        }
        if let data = UserDefaults.standard.data(forKey: Self.sessionTabsKey), let saved = try? decoder.decode([String: [Saved]].self, from: data) {
            sessionTabs = saved.mapValues { tabs in tabs.map { BrowserTab(url: $0.url, title: $0.title, browser: self) } }
        }
    }

    func favicon(of webView: WKWebView) async -> NSImage? {
        let script = "(() => { const links = [...document.querySelectorAll('link[rel~=\"icon\"]')]; const link = links.find((l) => l.sizes && /32|16/.test(l.sizes.value)) || links[0]; return link ? link.href : (location.protocol.startsWith('http') ? location.origin + '/favicon.ico' : null); })()"
        guard let href = try? await webView.evaluateJavaScript(script) as? String, let url = URL(string: href), let scheme = url.scheme?.lowercased() else { return nil }

        if scheme == "data" || scheme == "file" { return (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }
        guard !isSnapshot, scheme == "http" || scheme == "https" else { return nil }

        return await (try? Self.faviconSession.data(from: url).0).flatMap(NSImage.init(data:))
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let entry = BrowserDownload()
        downloadsByTask[ObjectIdentifier(download)] = entry
        progressObservations[ObjectIdentifier(download)] = download.progress.observe(\.fractionCompleted) { [weak entry] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in entry?.fraction = fraction }
        }
        downloads.append(entry)
    }

    func download(_ download: WKDownload, decideDestinationUsing _: URLResponse, suggestedFilename: String) async -> URL? {
        guard !isSnapshot, let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }

        let name = (suggestedFilename as NSString).deletingPathExtension
        let suffix = (suggestedFilename as NSString).pathExtension
        let candidates = [suggestedFilename] + (2...999).map { suffix.isEmpty ? "\(name) \($0)" : "\(name) \($0).\(suffix)" }
        let destination = candidates.lazy.map { folder.appending(path: $0) }.first { !FileManager.default.fileExists(atPath: $0.path) }
        downloadsByTask[ObjectIdentifier(download)]?.name = destination?.lastPathComponent ?? suggestedFilename
        downloadsByTask[ObjectIdentifier(download)]?.destination = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloadsByTask[ObjectIdentifier(download)]?.isFinished = true
        finish(download)
    }

    func download(_ download: WKDownload, didFailWithError _: any Error, resumeData _: Data?) {
        downloadsByTask[ObjectIdentifier(download)]?.failed = true
        finish(download)
    }

    private func finish(_ download: WKDownload) {
        downloadsByTask[ObjectIdentifier(download)] = nil
        progressObservations[ObjectIdentifier(download)] = nil
    }
}
