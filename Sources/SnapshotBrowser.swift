#if DEBUG
import AppKit
import BerthCore
import WebKit

extension Snapshot {
    static let browserFixtures: [SessionSummary]? = {
        guard UserDefaults.standard.bool(forKey: "snapshotBrowser") else { return nil }

        let folder = NSTemporaryDirectory() + "berth-browser"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return [SessionSummary(id: "fixture-browser", cwd: folder, title: "Export invoices as CSV", lastActivity: .now)]
    }()

    private static let browserPages: [(file: String, title: String, color: String, body: String)] = [
        ("docs.html", "Berth Docs", "#5b8def", "<h1>Berth Docs</h1><p>Sessions, Review and the Browser pane.</p>"),
        ("status.html", "Status Board", "#3fb950", "<h1>Status Board</h1><p>All systems normal.</p>"),
        ("invoices.html", "Invoices", "#d29922", """
        <h1>Invoices</h1><p>6 invoices this month for acme/billing</p>
        <table><tr><th>Invoice</th><th>Customer</th><th>Total</th><th>Status</th></tr>
        <tr><td>INV-1048</td><td>Northwind</td><td>€1 240,00</td><td>Paid</td></tr>
        <tr><td>INV-1047</td><td>Globex</td><td>€89,90</td><td>Open</td></tr>
        <tr><td>INV-1046</td><td>Initech</td><td>€4 312,50</td><td>Paid</td></tr>
        <tr><td>INV-1045</td><td>Umbrella</td><td>€310,00</td><td>Overdue</td></tr>
        <tr><td>INV-1044</td><td>Hooli</td><td>€2 015,75</td><td>Open</td></tr></table>
        """),
        ("api.html", "Export API", "#a371f7", "<h1>Export API</h1><p>Stream invoices as CSV from the billing service.</p><pre>GET /v1/invoices/export?format=csv</pre>"),
        ("pr.html", "Pull Request 418", "#f85149", "<h1>Export invoices as CSV</h1><p>feat/invoice-export into main</p>"),
        ("release.html", "Release Checklist", "#39c5cf", "<h1>Release Checklist</h1><ul><li>Verify the CSV headers</li><li>Publish the export documentation</li></ul>"),
    ]

    static func probeIncomingURL(_ text: String, store: Store) {
        let before = store.sessionTab.map { store.browser.tabs(in: BrowserModel.key(of: $0)).count } ?? 0
        store.openIncomingURL(URL(string: text)!)
        let session = store.sessionTab
        let tabs = session.map { store.browser.tabs(in: BrowserModel.key(of: $0)) } ?? []
        print("incoming url \(text): session \(session != nil), browser tabs \(before) -> \(tabs.count), newest \(tabs.last?.url?.absoluteString ?? "-"), pane \(store.shownPane?.rawValue ?? "hidden"), launcher \(store.launcherMode.map { "\($0)" } ?? "closed"), pending \(store.pendingIncomingURL?.absoluteString ?? "-")")
    }

    static func captureBrowser(store: Store, window: NSWindow) async {
        guard let session = browserFixtures?.first else { return }

        let folder = URL(filePath: session.cwd)
        for page in browserPages {
            let icon = "data:image/svg+xml;base64," + Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'><rect width='16' height='16' rx='4' fill='\(page.color)'/></svg>".utf8).base64EncodedString()
            let html = "<!doctype html><html><head><meta charset='utf-8'><title>\(page.title)</title><link rel='icon' href='\(icon)'><style>body{font:14px -apple-system,sans-serif;margin:32px;color:#1f2328}@media(prefers-color-scheme:dark){body{background:#1e1f22;color:#e6e6e6}}table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:8px;border-bottom:1px solid #8884}</style></head><body>\(page.body)</body></html>"
            try? Data(html.utf8).write(to: folder.appending(path: page.file))
        }
        await store.browser.prepareSnapshotRules()

        let parent = UUID()
        store.openShell(cwd: session.cwd, id: parent)
        store.tabs = store.tabs.map { $0.id == parent ? Tab(id: parent, kind: .claude, cwd: session.cwd, sessionID: session.id, terminal: $0.terminal) : $0 }
        store.activate(.tab(parent))
        let extraTabs = max(0, UserDefaults.standard.integer(forKey: "snapshotBrowserExtraTabs"))
        for index in 0..<extraTabs {
            store.browser.open(nil, in: session.id, title: "Document \(index + 1)", selects: false)
        }
        let scenario = UserDefaults.standard.string(forKey: "snapshotBrowserPin") ?? ""
        if scenario == "single" || scenario == "pinOnly" {
            let tab = store.browser.open(folder.appending(path: "invoices.html"), in: session.id, title: "Invoices")
            if scenario == "pinOnly" { store.browser.pin(tab) }
        } else if scenario == "pinnedSelected" {
            let tabs = browserPages.prefix(4).map { store.browser.open(folder.appending(path: $0.file), in: session.id, title: $0.title) }
            tabs.prefix(2).forEach { store.browser.pin($0) }
            store.browser.select(tabs[0], in: session.id)
        } else if scenario == "grid" {
            let defaults = UserDefaults.standard
            let pinnedCount = defaults.integer(forKey: "snapshotBrowserPinned")
            let sessionCount = defaults.integer(forKey: "snapshotBrowserSessions")
            let tabs = (0..<(pinnedCount + sessionCount)).map { index in
                let page = browserPages[index % browserPages.count]
                return store.browser.open(folder.appending(path: page.file), in: session.id, title: page.title, selects: false)
            }
            tabs.prefix(pinnedCount).forEach { store.browser.pin($0) }
            store.browser.select(defaults.string(forKey: "snapshotBrowserSelect") == "pinned" ? tabs[0] : tabs[pinnedCount], in: session.id)
        } else if scenario == "pinnedActive" {
            let docs = store.browser.open(folder.appending(path: "docs.html"), in: session.id, title: "Berth Docs")
            store.browser.open(folder.appending(path: "invoices.html"), in: session.id, title: "Invoices", selects: false)
            store.browser.pin(docs)
        } else {
            for (index, page) in browserPages.enumerated() {
                let tab = store.browser.open(folder.appending(path: page.file), in: session.id, title: page.title)
                if index < 2 { store.browser.pin(tab) }
            }
            store.browser.select(store.browser.tabs(in: session.id)[extraTabs], in: session.id)
        }
        if UserDefaults.standard.bool(forKey: "snapshotBrowserAgent") {
            store.browser.open(URL(string: "http://127.0.0.1:45779/session-4f9a1c2e-7b3d-4e8a-9c15-0d2e6f8a1b37/dashboard")!, in: session.id, title: "Dev Server").isDrivenByAgent = true
        }
        store.showBrowserPane()
        for tab in store.browser.pinned + store.browser.tabs(in: session.id) where tab.url != nil {
            let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            print("browser occlusion SPI \(tab.webView.responds(to: selector))")
            if tab.webView.responds(to: selector) { tab.webView.perform(selector, with: nil) }
        }
        try? await Task.sleep(for: .seconds(3))

        if let history = UserDefaults.standard.string(forKey: "snapshotBrowserHistory"), let tab = store.browser.shownTab {
            let view = tab.webView
            tab.load(folder.appending(path: "api.html"))
            await tab.waitForNavigation(in: view)
            if history == "both" {
                tab.load(folder.appending(path: "pr.html"))
                await tab.waitForNavigation(in: view)
            }
            if history == "both" || history == "forward" {
                store.browser.perform(.browserBack)
                try? await Task.sleep(for: .milliseconds(300))
                await tab.waitForNavigation(in: view)
            }
        }

        if UserDefaults.standard.bool(forKey: "snapshotBrowserFocusAddress") {
            let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
            let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
            method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
            method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
            window.becomeKey()
            AppAction.openLocation.perform(on: store)
            try? await Task.sleep(for: .seconds(1))
        }
        if UserDefaults.standard.bool(forKey: "snapshotBrowserNewTab") { await probeNewTabKeyViewLoop(store: store, window: window) }
        let shown = store.browser.shownTab
        let pinned = store.browser.pinned
        let sessionTabs = store.browser.tabs(in: session.id)
        let all = pinned + sessionTabs
        let hovered = all.map(\.displayTitle).filter { forcedHover.contains($0) }
        print("browser pane \(store.shownPane?.rawValue ?? "hidden"), window width \(window.contentLayoutRect.width), pinned \(pinned.count) \(pinned.map(\.displayTitle)), session \(sessionTabs.count) \(sessionTabs.map(\.displayTitle)), favicons \(all.count(where: { $0.favicon != nil })), hovered \(hovered), shown \(shown?.displayTitle ?? "none") \(shown?.url?.lastPathComponent ?? "-") loading \(shown?.isLoading == true), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
        print("browser history back \(shown?.canGoBack == true), forward \(shown?.canGoForward == true)")
        if let view = shown?.loadedWebView {
            let userAgent = try? await view.evaluateJavaScript("navigator.userAgent") as? String
            print("browser user agent \(userAgent ?? "unavailable")")
            let scheme = try? await view.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'") as? String
            print("browser prefers-color-scheme \(scheme ?? "unavailable")")
        }
        if UserDefaults.standard.bool(forKey: "snapshotPaneWidths") { await probePaneWidths(store: store, window: window) }
        if UserDefaults.standard.bool(forKey: "snapshotRememberedSizes") { await probeRememberedSizes(store: store, window: window) }
        if UserDefaults.standard.bool(forKey: "snapshotModeSwitch") { await probeModeSwitch(store: store, window: window) }
    }

    private static func probeModeSwitch(store: Store, window: NSWindow) async {
        guard let session = store.sessionTab else {
            print("mode switch FAIL: no session")
            return
        }

        func diffColumnIsCollapsed(in view: NSView) -> Bool? {
            if let controller = (view as? NSSplitView)?.delegate as? TerminalSplitController { return controller.diff?.isCollapsed }
            return view.subviews.lazy.compactMap(diffColumnIsCollapsed).first
        }

        func settle() async {
            try? await Task.sleep(for: .milliseconds(400))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func check(_ label: String, expects mode: SessionPane) async {
            store.selectPane(mode)
            await settle()
            let isColumnShown = window.contentView.flatMap(diffColumnIsCollapsed) == false
            print("mode switch \(label) -> \(mode.title) \(store.shownPane == mode && store.sessionPane == mode && isColumnShown ? "PASS" : "FAIL"): shown \(store.shownPane?.title ?? "hidden"), column \(isColumnShown ? "visible" : "collapsed")")
        }

        let key = BrowserModel.key(of: session)
        let docs = store.browser.open(URL(string: "about:blank"), in: key, title: "Docs")
        store.browser.pin(docs)
        for step in ["opened tab", "navigated", "pinned selected", "session tab selected"] {
            store.showBrowserPane()
            switch step {
            case "opened tab": store.browser.open(nil, in: key)
            case "navigated": store.browser.shownTab?.load(URL(string: "about:blank")!)
            case "pinned selected": store.browser.select(docs, in: key)
            default: if let tab = store.browser.tabs(in: key).first { store.browser.select(tab, in: key) }
            }
            await settle()
            await check("browser after \(step)", expects: .changes)
        }

        for from in SessionPane.allCases where from != .tasks {
            for to in SessionPane.allCases where to != .tasks && to != from {
                store.selectPane(from)
                await settle()
                await check(from.title, expects: to)
            }
        }
    }

    private static func probePaneWidths(store: Store, window: NSWindow) async {
        func splitView(in view: NSView) -> NSSplitView? {
            if view.identifier?.rawValue == "terminalSplit" { return view as? NSSplitView }
            return view.subviews.lazy.compactMap(splitView).first
        }

        guard let root = window.contentView, let split = splitView(in: root), split.arrangedSubviews.count == 2,
              let controller = split.delegate as? NSSplitViewController, controller.splitViewItems.count == 2
        else {
            print("pane widths FAIL: split unavailable")
            return
        }

        let isPaneLeading = !split.isVertical || UserDefaults.standard.string(forKey: "sidebarPosition") == "right"
        let session = controller.splitViewItems[isPaneLeading ? 1 : 0].viewController.view
        let pane = split.arrangedSubviews[isPaneLeading ? 0 : 1]

        func widths() -> (session: CGFloat, divider: CGFloat, pane: CGFloat, split: CGFloat) {
            let insets = session.additionalSafeAreaInsets
            let divider = split.arrangedSubviews[0].convert(split.arrangedSubviews[0].bounds, to: nil)
            return (session.frame.width - insets.left - insets.right, split.isVertical ? divider.maxX : divider.minY, pane.frame.width, split.bounds.width)
        }

        let windowSize = window.contentRect(forFrameRect: window.frame).size
        for width in [windowSize.width + 1, windowSize.width] {
            window.setContentSize(NSSize(width: width, height: windowSize.height))
            root.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
        let beforeDrag = widths()
        let position = split.arrangedSubviews[0].frame
        let target = split.isVertical ? position.width + (isPaneLeading ? 100 : -100) : position.height + 100
        split.setPosition(target, ofDividerAt: 0)
        root.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        root.layoutSubtreeIfNeeded()
        let dragged = widths()
        let moved = abs(abs(dragged.divider - beforeDrag.divider) - 100) < 1
        print("pane widths drag \(moved ? "PASS" : "FAIL"): session \(beforeDrag.session) -> \(dragged.session), divider \(beforeDrag.divider) -> \(dragged.divider), pane \(beforeDrag.pane) -> \(dragged.pane), split \(beforeDrag.split) -> \(dragged.split)")

        for mode: SessionPane in [.changes, .files, .browser, .terminal, .changes, .browser, .files, .terminal, .browser, .changes, .terminal, .files, .changes, .browser] {
            let previous = store.shownPane
            let before = widths()
            switch mode {
            case .changes: store.showReviewPane(.changes)
            case .files: store.showReviewPane(.files)
            case .browser: store.showBrowserPane()
            case .terminal: store.showTerminalPane()
            case .tasks: store.showTasksPane()
            }
            try? await Task.sleep(for: .milliseconds(600))
            root.layoutSubtreeIfNeeded()
            let after = widths()
            let keptSize = split.isVertical ? abs(dragged.session - after.session) < 1 : abs(dragged.divider - after.divider) < 1
            let result = dragged.session > 0 && keptSize && store.shownPane == mode ? "PASS" : "FAIL"
            print("pane widths \(previous?.title ?? "Hidden") -> \(mode.title) \(result): session \(before.session) -> \(after.session), divider \(before.divider) -> \(after.divider), pane \(before.pane) -> \(after.pane), split \(before.split) -> \(after.split)")
        }

        let size = window.contentRect(forFrameRect: window.frame).size
        var passes = 0
        for width in [900.0, 1000, 1100, 1150, 1200, 1250, 1400, 1600] {
            window.setContentSize(NSSize(width: width, height: size.height))
            for mode: SessionPane in [.browser, .changes, .terminal, .files, .tasks] {
                switch mode {
                case .changes: store.showReviewPane(.changes)
                case .files: store.showReviewPane(.files)
                case .browser: store.showBrowserPane()
                case .terminal: store.showTerminalPane()
                case .tasks: store.showTasksPane()
                }
                for fraction in [0.1, 0.9, 0.5] {
                    split.setPosition(fraction * (split.isVertical ? split.bounds.width : split.bounds.height), ofDividerAt: 0)
                    try? await Task.sleep(for: .milliseconds(30))
                    passes += 1
                }
            }
        }
        for round in 0..<50 {
            if round.isMultiple(of: 2) { store.showBrowserPane() } else { store.showReviewPane(.changes) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        root.layoutSubtreeIfNeeded()
        print("pane widths stress PASS: \(passes) divider drags across 8 window widths and 5 modes without a layout exception")
    }

    private static func probeRememberedSizes(store: Store, window: NSWindow) async {
        func splitView(in view: NSView) -> NSSplitView? {
            if view.identifier?.rawValue == "terminalSplit" { return view as? NSSplitView }
            return view.subviews.lazy.compactMap(splitView).first
        }

        func settle() async {
            try? await Task.sleep(for: .milliseconds(700))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func show(_ mode: SessionPane) {
            switch mode {
            case .changes: store.showReviewPane(.changes)
            case .files: store.showReviewPane(.files)
            case .browser: store.showBrowserPane()
            case .terminal: store.showTerminalPane()
            case .tasks: store.showTasksPane()
            }
        }

        guard let root = window.contentView, let split = splitView(in: root), let controller = split.delegate as? TerminalSplitController, let terminal = controller.terminal?.viewController.view, let pane = controller.diff?.viewController.view,
              let sessionA = store.sessionTab
        else {
            print("remembered sizes FAIL: split unavailable")
            return
        }

        let isBelow = !split.isVertical
        func reserve() -> CGFloat { isBelow ? 0 : controller.browserSidebarWidth }
        func sizes() -> (session: CGFloat, pane: CGFloat) {
            isBelow ? (terminal.frame.height, pane.frame.height) : (terminal.frame.width, pane.frame.width)
        }

        let parent = UUID()
        store.openShell(cwd: sessionA.cwd, id: parent)
        store.tabs = store.tabs.map { $0.id == parent ? Tab(id: parent, kind: .claude, cwd: sessionA.cwd, sessionID: "fixture-other", terminal: $0.terminal) : $0 }
        store.activate(.tab(sessionA.id))
        store.showReviewPane(.changes)
        await settle()
        let start = sizes()
        split.setPosition(isBelow ? split.arrangedSubviews[0].frame.height + 90 : split.arrangedSubviews[0].frame.width + (controller.splitViewItems.first === controller.diff ? -90 : 90), ofDividerAt: 0)
        await settle()
        controller.persistsSizes = false
        controller.recordUserSize()
        let dragged = sizes()
        print("remembered sizes drag \(abs(dragged.session - start.session) > 50 ? "PASS" : "FAIL"): session \(start.session) -> \(dragged.session), pane \(start.pane) -> \(dragged.pane)")

        for mode: SessionPane in [.changes, .files, .browser, .terminal, .changes] {
            store.hideSessionPanel()
            await settle()
            let hidden = store.shownPane == nil
            show(mode)
            await settle()
            let after = sizes()
            let kept = abs(after.session - dragged.session) <= 1 && abs(after.pane - reserve() - dragged.pane) <= 1
            print("remembered sizes hide and show \(mode.title) \(hidden && kept && store.shownPane == mode ? "PASS" : "FAIL"): session \(dragged.session) -> \(after.session), pane \(dragged.pane) -> \(after.pane - reserve())")
        }

        store.showBrowserPane()
        await settle()
        store.activate(.tab(parent))
        store.showReviewPane(.files)
        await settle()
        let other = sizes()
        let sameAcrossSessions = store.sessionTab?.id == parent && abs(other.session - dragged.session) <= 1 && abs(other.pane - reserve() - dragged.pane) <= 1
        print("remembered sizes session switch \(sameAcrossSessions ? "PASS" : "FAIL"): A browser, B \(store.shownPane?.title ?? "hidden"), session \(dragged.session) -> \(other.session), pane \(dragged.pane) -> \(other.pane)")
        store.activate(.tab(sessionA.id))
        await settle()

        await probeRememberedSidebars(store: store, window: window, split: split)
        let size = window.contentRect(forFrameRect: window.frame).size
        for width in [1000.0, 700.0] {
            store.hideSessionPanel()
            window.setContentSize(isBelow ? NSSize(width: size.width, height: width * 0.6) : NSSize(width: width, height: size.height))
            await settle()
            store.showBrowserPane()
            for delay in [50, 250, 1200] {
                try? await Task.sleep(for: .milliseconds(delay))
                window.contentView?.layoutSubtreeIfNeeded()
                print("remembered sizes narrow trace \(Int(width)) +\(delay)ms: session \(sizes().session), pane \(sizes().pane), split \(split.bounds.width), reserve \(reserve()), gaps \(split.convert(split.bounds, to: nil).minX) \(window.contentLayoutRect.width - split.convert(split.bounds, to: nil).maxX)")
            }
            let narrow = sizes()
            let available = (isBelow ? split.bounds.height : split.bounds.width) - split.dividerThickness
            let minimum = isBelow ? 160 : min(360, (available - reserve()) * 0.6)
            let isUsable = narrow.session >= minimum - 1 && narrow.pane - reserve() > 0 && abs(narrow.session + narrow.pane - available) <= 1
            print("remembered sizes narrow window \(Int(width)) \(isUsable ? "PASS" : "FAIL"): session \(narrow.session), pane \(narrow.pane), available \(available)")
        }
        window.setContentSize(size)
        store.showReviewPane(.changes)
        await settle()
    }

    private static func probeRememberedSidebars(store: Store, window: NSWindow, split: NSSplitView) async {
        store.showReviewPane(.changes)
        let defaults = UserDefaults.standard
        let isRight = defaults.string(forKey: "sidebarPosition") == "right"
        defaults.set(330.0, forKey: "leadingSidebarWidth")
        defaults.set(250.0, forKey: "trailingSidebarWidth")
        defaults.set(350.0, forKey: "panelSidebarWidth")
        let expectedLeading = isRight ? 350.0 : 330.0
        let expectedTrailing = isRight ? 250.0 : 350.0
        let sidebarSplit = window.contentView.flatMap(sidebarSplitController)

        func gaps() -> (leading: CGFloat, trailing: CGFloat) {
            let frame = split.convert(split.bounds, to: nil)
            return (frame.minX - 8, window.contentLayoutRect.width - frame.maxX - 8)
        }

        func settle() async {
            try? await Task.sleep(for: .milliseconds(800))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        await settle()
        let before = gaps()
        print("remembered sizes sidebars before toggles: leading \(before.leading), trailing \(before.trailing), sidebar split found \(sidebarSplit != nil)")
        sidebarSplit?.toggleSidebar(nil)
        await settle()
        sidebarSplit?.toggleSidebar(nil)
        await settle()
        if isRight {
            defaults.set(false, forKey: "showsTrailingSidebar")
            await settle()
            defaults.set(true, forKey: "showsTrailingSidebar")
        } else {
            store.hideSessionPanel()
            await settle()
            store.showReviewPane(.changes)
        }
        await settle()
        let after = gaps()
        let isRestored = abs(after.leading - expectedLeading) <= 1 && abs(after.trailing - expectedTrailing) <= 1
        print("remembered sizes sidebars \(isRight ? "right" : "left") \(isRestored ? "PASS" : "FAIL"): leading \(after.leading) expected \(expectedLeading), trailing \(after.trailing) expected \(expectedTrailing)")
    }

    private static func probeNewTabKeyViewLoop(store: Store, window: NSWindow) async {
        let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
        let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
        method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
        method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
        window.becomeKey()
        if let key = store.browser.sessionKey { for extra in store.browser.pinned.dropFirst() { store.browser.unpin(extra, into: key) } }
        if let pinned = store.browser.pinned.first, let key = store.browser.sessionKey { store.browser.select(pinned, in: key) }
        try? await Task.sleep(for: .milliseconds(500))
        window.makeFirstResponder(nil)
        let arm = DispatchWorkItem {
            print("browser new tab key view probe FAIL: main thread blocked over 5 s")
            fflush(stdout)
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: arm)
        AppAction.newBrowserTab.perform(on: store)
        try? await Task.sleep(for: .seconds(1))
        arm.cancel()

        guard let field = window.firstResponder as? NSView else {
            print("browser new tab key view probe FAIL: no focused view")
            exit(1)
        }

        let watchdog = DispatchWorkItem {
            print("browser new tab key view probe FAIL: previousValidKeyView did not return within 1 s")
            fflush(stdout)
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: watchdog)
        let target = (field as? NSTextView)?.delegate as? NSView ?? field
        let previous = target.previousValidKeyView
        let next = target.nextValidKeyView
        window.recalculateKeyViewLoop()
        window.selectPreviousKeyView(nil)
        window.selectNextKeyView(nil)
        watchdog.cancel()
        print("browser new tab key view probe PASS: \(type(of: target)) previous \(previous.map { "\(type(of: $0))" } ?? "nil") next \(next.map { "\(type(of: $0))" } ?? "nil")")
    }

    static func logBrowserAddress(in window: NSWindow) {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            print("browser address responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            return
        }

        print("browser address editor frame \(editor.frame), selection \(editor.selectedRange()), text length \(editor.string.utf16.count)")
    }
}
#endif
