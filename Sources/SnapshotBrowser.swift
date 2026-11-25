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
        for (index, page) in browserPages.enumerated() {
            let tab = store.browser.open(folder.appending(path: page.file), in: session.id, title: page.title)
            if index < 2 { store.browser.pin(tab) }
        }
        store.browser.select(store.browser.tabs(in: session.id)[extraTabs], in: session.id)
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
