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

enum BrowserAppearance: String, CaseIterable {
    case auto, light, dark

    var title: String {
        [.auto: "Auto", .light: "Light", .dark: "Dark"][self] ?? rawValue
    }

    var appearance: NSAppearance? {
        let systemIsDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let named: [Self: NSAppearance.Name] = [.auto: systemIsDark ? .darkAqua : .aqua, .light: .aqua, .dark: .darkAqua]
        return named[self].flatMap { NSAppearance(named: $0) }
    }
}

enum BrowserLinkTarget: String {
    case defaultBrowser, berth
}

@Observable
final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private static let showInspectorSelector = NSSelectorFromString("show")

    let id = UUID()
    var url: URL?
    var lockedURL: URL?
    var title: String
    var favicon: NSImage?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var isDrivenByAgent = false
    @ObservationIgnored var needsPageFocus = false
    @ObservationIgnored private(set) var loadedWebView: WKWebView?
    @ObservationIgnored var isTakingScreenshot = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pendingNavigation: WKNavigation?
    @ObservationIgnored private(set) var navigationSequence = 0
    @ObservationIgnored private var navigationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var consoleEntries: [ControlConsoleEntry] = []
    @ObservationIgnored private var consoleSequence = 0
    @ObservationIgnored private unowned let browser: BrowserModel

    init(url: URL?, title: String = "", lockedURL: URL? = nil, browser: BrowserModel) {
        self.url = url
        self.title = title
        self.lockedURL = lockedURL
        self.browser = browser
    }

    var isLocked: Bool { lockedURL != nil }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host(percentEncoded: false) ?? url?.lastPathComponent ?? "New Tab"
    }

    var webView: WKWebView {
        if let loadedWebView { return loadedWebView }

        let configuration = browser.configuration()
        installUserScripts(in: configuration.userContentController)
        configuration.userContentController.add(self, name: Self.consoleBridge)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.appearance = BrowserAppearance(rawValue: UserDefaults.standard.string(forKey: BrowserModel.appearanceKey) ?? "")?.appearance
        view.isInspectable = true
        observations = [
            view.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { if let title = view.title, !title.isEmpty { self?.title = title } } },
            view.observe(\.url, options: [.old]) { [weak self] view, change in
                let previousURL = change.oldValue ?? nil
                MainActor.assumeIsolated {
                    guard let self, let url = view.url else { return }
                    guard let lockedURL = self.lockedURL, !view.isLoading, let previousURL,
                          PageLock.isSamePage(previousURL, lockedURL), !PageLock.isSamePage(url, lockedURL)
                    else {
                        self.url = url
                        return
                    }

                    self.browser.openFromPage(url, opener: self, selects: true)
                    if let previousItem = view.backForwardList.backItem, PageLock.isSamePage(previousItem.url, lockedURL) {
                        view.goBack()
                    } else {
                        self.pendingNavigation = view.load(URLRequest(url: lockedURL))
                    }
                }
            },
            view.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
            view.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            view.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
        loadedWebView = view
        if let url, browser.mayLoad { pendingNavigation = view.load(URLRequest(url: url)) }
        return view
    }

    var webInspector: NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard let view = loadedWebView, view.responds(to: selector),
              let inspector = view.perform(selector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: Self.showInspectorSelector)
        else { return nil }

        return inspector
    }

    var canShowInspector: Bool {
        UserDefaults.standard.bool(forKey: BrowserModel.developerToolsKey) && webInspector != nil
    }

    @discardableResult
    func showInspector() -> Bool {
        guard UserDefaults.standard.bool(forKey: BrowserModel.developerToolsKey), let webInspector else { return false }

        webInspector.perform(Self.showInspectorSelector)
        return true
    }

    private func installUserScripts(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: Self.consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let source = Self.scrollerScript + "(\(browser.scrollerStyle.isLegacy));"
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.scrollerWorld))
    }

    func updateScrollerStyle(reinstallScripts: Bool = true) {
        guard let view = loadedWebView else { return }

        if reinstallScripts {
            installUserScripts(in: view.configuration.userContentController)
            if #available(macOS 27.0, *) { view.superview?.invalidateCornerConfiguration() }
        }
        let source = "globalThis.berthSetLegacyScrollbars?.(\(browser.scrollerStyle.isLegacy))"
        view.evaluateJavaScript(source, in: nil, in: Self.scrollerWorld, completionHandler: nil)
    }

    func load(_ url: URL) {
        if let lockedURL, let currentURL = loadedWebView?.url,
           PageLock.isSamePage(currentURL, lockedURL), !PageLock.isSamePage(url, lockedURL) {
            browser.openFromPage(url, opener: self, selects: true)
            return
        }

        self.url = url
        guard browser.mayLoad else { return }

        if let loadedWebView {
            pendingNavigation = loadedWebView.load(URLRequest(url: url))
        } else {
            _ = webView
        }
    }

    func reload() {
        if let loadedWebView {
            pendingNavigation = loadedWebView.reload()
        } else {
            _ = webView
        }
    }

    func unload() {
        observations = []
        loadedWebView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.consoleBridge)
        loadedWebView?.stopLoading()
        loadedWebView?.removeFromSuperview()
        loadedWebView = nil
        needsPageFocus = false
        isLoading = false
        progress = 0
        finishNavigation()
    }

    var isNavigating: Bool {
        pendingNavigation != nil || loadedWebView?.isLoading == true
    }

    func waitForNavigation(in view: WKWebView) async {
        guard pendingNavigation != nil || view.isLoading else { return }

        let id = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { self?.navigationWaiters.removeValue(forKey: id)?.resume() }
        }
        defer { timeout.cancel() }

        await withCheckedContinuation { navigationWaiters[id] = $0 }
    }

    private func finishNavigation() {
        pendingNavigation = nil
        let waiters = navigationWaiters.values
        navigationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if action.shouldPerformDownload { return (.download, preferences) }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return (.allow, preferences) }

        if browser.isSnapshot, !["file", "about", "data", "blob"].contains(scheme) {
            print("snapshot browser blocked \(url.absoluteString)")
            return (.cancel, preferences)
        }
        let opensInNewTab = action.navigationType == .linkActivated && (action.modifierFlags.contains(.command) || action.buttonNumber == 4)
        let isPage = ["http", "https", "file"].contains(scheme)
        if opensInNewTab, isPage {
            browser.openFromPage(url, opener: self, selects: action.modifierFlags.contains(.shift))
            return (.cancel, preferences)
        }
        if isPage, action.targetFrame?.isMainFrame == true, let lockedURL, let currentURL = webView.url,
           PageLock.isSamePage(currentURL, lockedURL), !PageLock.isSamePage(url, lockedURL) {
            if action.navigationType != .backForward { browser.openFromPage(url, opener: self, selects: true) }
            return (.cancel, preferences)
        }
        if isPage || ["about", "data", "blob", "javascript"].contains(scheme) { return (.allow, preferences) }

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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard webView === loadedWebView else { return }

        navigationSequence += 1
        pendingNavigation = navigation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard webView === loadedWebView else { return }

        updateScrollerStyle(reinstallScripts: false)
        if navigation === pendingNavigation { finishNavigation() }
        browser.save()
        Task { favicon = await browser.favicon(of: webView) ?? favicon }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        guard webView === loadedWebView else { return }

        if navigation === pendingNavigation { finishNavigation() }
        let failure = error as NSError
        if failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled {
            recordConsole(level: "error", text: "Navigation failed: \(failure.localizedDescription)")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.consoleBridge, message.frameInfo.isMainFrame, message.webView === loadedWebView,
              let body = message.body as? [String: Any], body.count == 2, let level = body["level"] as? String,
              ["log", "info", "warn", "error", "debug"].contains(level), let text = body["text"] as? String
        else { return }

        recordConsole(level: level, text: text)
    }

    func console(since: Int?) -> ControlResponse {
        let start = max(since ?? 0, consoleSequence - consoleEntries.count)
        // A JSON-escaped scalar can occupy six bytes on the control socket.
        let end = start + min(64, max(0, consoleSequence - start))
        let entries = (start..<end).map { consoleEntries[$0 % ControlConsoleEntry.bufferCapacity] }
        return ControlResponse(tab: id.uuidString, console: entries, consoleHasMore: end < consoleSequence ? true : nil)
    }

    private func recordConsole(level: String, text: String) {
        consoleSequence += 1
        let entry = ControlConsoleEntry(sequence: consoleSequence, level: level, text: String(text.unicodeScalars.prefix(2000)), timestamp: .now)
        if consoleEntries.count < ControlConsoleEntry.bufferCapacity {
            consoleEntries.append(entry)
        } else {
            consoleEntries[(consoleSequence - 1) % ControlConsoleEntry.bufferCapacity] = entry
        }
    }

    func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }

        let isBackground = action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift)
        browser.openFromPage(url, opener: self, selects: !isBackground)
        return nil
    }

    private static let scrollerWorld = WKContentWorld.world(name: "Berth Scrollbars")
    private static let scrollerScript = """
    (legacy => {
      const style = document.createElement('style');
      style.id = 'berth-legacy-scrollbars';
      style.textContent = `
        ::-webkit-scrollbar { width: 17px; height: 17px; }
        ::-webkit-scrollbar-track, ::-webkit-scrollbar-corner { background: #fafafa; }
        ::-webkit-scrollbar-track:vertical {
          border-left: 1px solid #e8e8e8;
          margin-block: 0 \(CardBorder.radius)px;
        }
        ::-webkit-scrollbar-track:horizontal { border-top: 1px solid #e8e8e8; }
        ::-webkit-scrollbar-thumb {
          background-color: #c1c1c1;
          border: 3px solid transparent;
          border-radius: 10px;
          background-clip: padding-box;
        }
        ::-webkit-scrollbar-thumb:hover { background-color: #a8a8a8; }
        @media (prefers-color-scheme: dark) {
          ::-webkit-scrollbar-track, ::-webkit-scrollbar-corner { background: #1e1e1e; }
          ::-webkit-scrollbar-track:vertical { border-left-color: #333333; }
          ::-webkit-scrollbar-track:horizontal { border-top-color: #333333; }
          ::-webkit-scrollbar-thumb { background-color: #5a5a5a; }
          ::-webkit-scrollbar-thumb:hover { background-color: #787878; }
        }
      `;
      const apply = () => {
        if (!legacy) return style.remove();
        if (document.documentElement) document.documentElement.append(style);
      };
      globalThis.berthSetLegacyScrollbars = enabled => {
        legacy = enabled;
        apply();
      };
      if (document.documentElement) {
        apply();
        return;
      }
      const observer = new MutationObserver(() => {
        if (!document.documentElement) return;
        observer.disconnect();
        apply();
      });
      observer.observe(document, { childList: true });
    })
    """

    private static let consoleBridge = "berthConsole"
    private static let consoleScript = #"""
    (() => {
      const handler = window.webkit.messageHandlers.berthConsole;
      const post = handler.postMessage.bind(handler);
      const send = (level, text) => {
        try { post({ level, text: text.slice(0, 2000) }); } catch { return; }
      };
      const format = value => {
        try { return value instanceof Error ? String(value) : typeof value === 'object' ? JSON.stringify(value) ?? String(value) : String(value); }
        catch { return '[unprintable]'; }
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = function (...args) {
          send(level, args.map(format).join(' '));
          return Reflect.apply(original, this, args);
        };
      }
      window.addEventListener('error', event => {
        if (event instanceof ErrorEvent) send('error', event.message);
      });
      window.addEventListener('unhandledrejection', event => send('error', 'Unhandled promise rejection: ' + format(event.reason)));
      const fetch = window.fetch;
      window.fetch = function (...args) {
        return Reflect.apply(fetch, this, args).then(response => {
          if (response.status >= 400) send('error', 'Fetch HTTP ' + response.status + ' ' + response.url);
          return response;
        }, error => {
          send('error', 'Fetch failed: ' + format(error));
          throw error;
        });
      };
      const sendXHR = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function (...args) {
        this.addEventListener('loadend', () => {
          if (this.status >= 400) send('error', 'XHR HTTP ' + this.status + ' ' + this.responseURL);
        }, { once: true });
        return Reflect.apply(sendXHR, this, args);
      };
    })();
    """#
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

private struct ClosedTab {
    let url: URL?
    let title: String
    let index: Int
    let isPinned: Bool
}

@Observable
final class BrowserModel: NSObject, WKDownloadDelegate {
    static let searchKey = "browserSearchEngine"
    static let persistentDataKey = "browserKeepsWebsiteData"
    static let linksKey = "conversationLinksOpenIn"
    static let githubLinksKey = "githubLinksOpenInBerth"
    static let appearanceKey = "browserAppearance"
    static let developerToolsKey = "browserDeveloperTools"
    private static let pinnedKey = "browserPinnedTabs"
    private static let sessionTabsKey = "browserSessionTabs"
    private static let closedTabLimit = 20
    private static let ephemeralStore = WKWebsiteDataStore.nonPersistent()
    private static let faviconSession = URLSession(configuration: .ephemeral)

    private struct Saved: Codable {
        let url: URL?
        let title: String
        let lockedURL: URL?
    }

    var pinned: [BrowserTab] = []
    var sessionTabs: [String: [BrowserTab]] = [:]
    var selectedIDs: [String: BrowserTab.ID] = [:]
    var downloads: [BrowserDownload] = []
    var addressFocusRequests = 0
    @ObservationIgnored private var closedTabs: [String: [ClosedTab]] = [:]
    let access = BrowserAccess()
    let scrollerStyle = SystemScrollerStyle()
    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var appearanceObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var snapshotRules: WKContentRuleList?
    @ObservationIgnored var lastPaneSize = NSSize(width: 1280, height: 800)
    @ObservationIgnored private var downloadsByTask: [ObjectIdentifier: BrowserDownload] = [:]
    @ObservationIgnored private var progressObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(store: Store) {
        self.store = store
        super.init()
        scrollerStyle.onChange = { [weak self] in
            guard let self else { return }

            for tab in pinned + sessionTabs.values.flatMap(\.self) { tab.updateScrollerStyle() }
        }
        appearanceObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    func applyAppearance() {
        let appearance = BrowserAppearance(rawValue: UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "")?.appearance
        for tab in pinned + sessionTabs.values.flatMap(\.self) { tab.loadedWebView?.appearance = appearance }
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
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        configuration.websiteDataStore = !isSnapshot && UserDefaults.standard.bool(forKey: Self.persistentDataKey) ? .default() : Self.ephemeralStore
        // WebKit exposes in-app inspection through private API.
        let preferences = configuration.preferences
        if UserDefaults.standard.bool(forKey: Self.developerToolsKey), preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
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
        if selects, url == nil { addressFocusRequests += 1 }
        save()
        return tab
    }

    func setAgentAccess(_ decision: BrowserAccess.Decision, for key: String) {
        access.decide(decision, for: key)
        guard decision == .denied else { return }

        for tab in tabs(in: key) { tab.isDrivenByAgent = false }
    }

    func openFromPage(_ url: URL, opener: BrowserTab, selects: Bool = true) {
        let key = sessionTabs.first { $0.value.contains { $0 === opener } }?.key ?? sessionKey
        guard let key else { return }

        open(url, in: key, selects: selects)
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
        let isPinned = pinned.contains { $0 === tab }
        let siblings = isPinned ? pinned : tabs(in: key)
        let index = siblings.firstIndex { $0 === tab } ?? 0
        if tab.url != nil {
            closedTabs[key, default: []].append(ClosedTab(url: tab.url, title: tab.title, index: index, isPinned: isPinned))
            if closedTabs[key, default: []].count > Self.closedTabLimit { closedTabs[key]?.removeFirst() }
        }
        tab.unload()
        pinned.removeAll { $0 === tab }
        sessionTabs[key]?.removeAll { $0 === tab }
        if selectedIDs[key] == tab.id {
            let remaining = siblings.filter { $0 !== tab }
            selectedIDs[key] = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        save()
    }

    func reopenClosedTab(in key: String) {
        guard let closed = closedTabs[key]?.popLast() else { return }

        let tab = BrowserTab(url: closed.url, title: closed.title, browser: self)
        if closed.isPinned { pin(tab, at: closed.index) } else { unpin(tab, into: key, at: closed.index) }
        tab.needsPageFocus = true
        select(tab, in: key)
    }

    func pin(_ tab: BrowserTab, at index: Int? = nil) {
        for key in sessionTabs.keys { sessionTabs[key]?.removeAll { $0 === tab } }
        pinned.removeAll { $0 === tab }
        pinned.insert(tab, at: min(index ?? pinned.count, pinned.count))
        save()
    }

    func unpin(_ tab: BrowserTab, into key: String, at index: Int? = nil) {
        pinned.removeAll { $0 === tab }
        tab.lockedURL = nil
        sessionTabs[key]?.removeAll { $0 === tab }
        let count = tabs(in: key).count
        sessionTabs[key, default: []].insert(tab, at: min(index ?? count, count))
        save()
    }

    func lock(_ tab: BrowserTab) {
        guard pinned.contains(where: { $0 === tab }), let url = tab.url else { return }

        tab.lockedURL = url
        save()
    }

    func unlock(_ tab: BrowserTab) {
        tab.lockedURL = nil
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
        if action == .reopenBrowserTab { return reopenClosedTab(in: key) }
        guard let tab = shownTab else { return }

        if action == .closeBrowserTab { return close(tab, in: key) }
        if action == .reloadPage, tab.loadedWebView != nil { tab.reload() }
        if action == .showWebInspector { tab.showInspector() }
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

        let encode = { (tabs: [BrowserTab]) in tabs.compactMap { tab in tab.url.map { Saved(url: $0, title: tab.title, lockedURL: nil) } } }
        let savedPinned = pinned.compactMap { tab in tab.url.map { Saved(url: $0, title: tab.title, lockedURL: tab.lockedURL) } }
        UserDefaults.standard.set(try? JSONEncoder().encode(savedPinned), forKey: Self.pinnedKey)
        UserDefaults.standard.set(try? JSONEncoder().encode(sessionTabs.filter { !$0.value.isEmpty }.mapValues(encode)), forKey: Self.sessionTabsKey)
    }

    func restore() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: Self.pinnedKey), let saved = try? decoder.decode([Saved].self, from: data) {
            pinned = saved.map { BrowserTab(url: $0.url, title: $0.title, lockedURL: $0.lockedURL, browser: self) }
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
