#if DEBUG
import AppKit
import BerthCore

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
        <img src="https://example.com/tracker.png" width="1" height="1">
        """),
        ("api.html", "Export API", "#a371f7", "<h1>Export API</h1><p>Stream invoices as CSV from the billing service.</p><pre>GET /v1/invoices/export?format=csv</pre>"),
        ("pr.html", "Pull Request 418", "#f85149", "<h1>Export invoices as CSV</h1><p>feat/invoice-export into main</p>"),
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
        let urls = browserPages.map { folder.appending(path: $0.file) }
        for url in urls.prefix(2) { store.browser.pin(store.browser.open(url, in: session.id)) }
        for url in urls.dropFirst(2) { store.browser.open(url, in: session.id) }
        if let invoices = store.browser.tabs(in: session.id).first { store.browser.select(invoices, in: session.id) }
        store.showBrowserPane()
        for tab in store.browser.pinned + store.browser.tabs(in: session.id) { 
            let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            print("browser occlusion SPI \(tab.webView.responds(to: selector))")
            if tab.webView.responds(to: selector) { tab.webView.perform(selector, with: nil) }
        }
        try? await Task.sleep(for: .seconds(3))

        if UserDefaults.standard.bool(forKey: "snapshotBrowserFocusAddress") {
            let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
            let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
            method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
            method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
            window.becomeKey()
            AppAction.openLocation.perform(on: store)
            try? await Task.sleep(for: .seconds(1))
        }
        let shown = store.browser.shownTab
        print("browser pane \(store.shownPane?.rawValue ?? "hidden"), pinned \(store.browser.pinned.map(\.displayTitle)), session \(store.browser.tabs(in: session.id).map(\.displayTitle)), favicons \((store.browser.pinned + store.browser.tabs(in: session.id)).filter { $0.favicon != nil }.count), shown \(shown?.displayTitle ?? "none") \(shown?.url?.lastPathComponent ?? "-") loading \(shown?.isLoading == true), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
    }
}
#endif
