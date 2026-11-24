#if DEBUG
import AppKit
import BerthCore
import CoreGraphics
import Foundation
import WebKit

extension Snapshot {
    static func captureControlBrowser(store: Store, window: NSWindow, output: URL) async {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil,
              UserDefaults.standard.bool(forKey: ControlService.enabledKey), let tool = ControlService.cliTool
        else { fail("-snapshotControlBrowser needs CFFIXED_USER_HOME, -controlEnabled YES and the embedded berth-cli") }

        do {
            try await probeControlBrowser(store: store, tool: tool)
            guard let image = image(of: window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fail("couldn’t capture the browser control window")
            }

            try png.write(to: output)
        } catch {
            fail(error.localizedDescription)
        }
        store.isTerminating = true
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }

    private static func probeControlBrowser(store: Store, tool: URL) async throws {
        await store.browser.prepareSnapshotRules()
        let folder = FileManager.default.temporaryDirectory.appending(path: "berth-control-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let loggedPage = folder.appending(path: "console.html")
        let tallPage = folder.appending(path: "tall.html")
        let simplePage = folder.appending(path: "simple.html")
        try Data("""
        <!doctype html><title>Control Console</title><h1>Browser control fixture text</h1>
        <script>
        addEventListener('load', () => {
          console.log('control fixture log');
          console.warn('control fixture warning');
          console.error('control fixture error');
          setTimeout(() => { throw new Error('control fixture uncaught'); }, 0);
        });
        </script>
        """.utf8).write(to: loggedPage)
        try Data("""
        <!doctype html><title>Tall Fixture</title>
        <body style="margin:0;background:#2054bf">
          <div style="height:600px;background:#c72a59"><h1 style="margin:0">Tall fixture top</h1></div>
          <div style="height:3100px"></div>
          <div style="height:300px;background:#24b74c">Tall fixture bottom</div>
        </body>
        """.utf8).write(to: tallPage)
        try Data("<!doctype html><title>Simple Fixture</title><p>Other browser tab</p>".utf8).write(to: simplePage)

        store.control.update()
        let session = UUID()
        let otherSession = UUID()
        let caller = UUID()
        let outsider = UUID()
        for id in [session, otherSession] {
            store.openShell(cwd: folder.path, command: "exec cat", id: id)
        }
        store.tabs = store.tabs.map { tab in
            guard tab.id == session || tab.id == otherSession else { return tab }

            return Tab(id: tab.id, kind: .claude, cwd: folder.path, sessionID: tab.id.uuidString, terminal: tab.terminal)
        }
        store.openShell(cwd: folder.path, command: "exec cat", id: caller, parent: session)
        store.openShell(cwd: folder.path, command: "exec cat", id: outsider)
        let environment = store.control.environment(for: caller)
        guard !environment.isEmpty else { fail(store.control.failure ?? "browser control socket unavailable") }

        let browser = store.browser
        let key = session.uuidString
        let tall = browser.open(tallPage, in: key, title: "Tall Fixture", selects: false)
        let pinned = browser.open(simplePage, in: key, title: "Pinned Fixture", selects: false)
        browser.pin(pinned)
        let active = browser.open(loggedPage, in: key, title: "Control Console")
        let other = browser.open(simplePage, in: otherSession.uuidString, title: "Other Session Fixture")
        store.activate(.tab(session))
        store.showBrowserPane()
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if active.webView.responds(to: selector) { active.webView.perform(selector, with: nil) }

        func berth(_ args: String..., asOutsider: Bool = false) async -> (status: Int32, output: String) {
            let result = await runControlCLI(tool, arguments: ["browser"] + args, environment: asOutsider ? store.control.environment(for: outsider) : environment)
            print("browser \(args.joined(separator: " ")) [\(result.status)] \(result.output)")
            return result
        }

        let activeID = String(active.id.uuidString.lowercased().prefix(8))
        let tallID = String(tall.id.uuidString.lowercased().prefix(8))
        let listed = await berth("tabs", "--json")
        let tabs = try JSONDecoder().decode(ControlResponse.self, from: Data(listed.output.utf8)).browserTabs
        guard listed.status == 0, tabs?.map(\.id) == [tallID, activeID], tabs?.filter(\.active).map(\.id) == [activeID] else {
            fail("browser tabs should list the caller’s two session tabs")
        }

        for denied in [pinned, other] {
            let id = String(denied.id.uuidString.lowercased().prefix(8))
            let result = await berth("screenshot", "--tab", id)
            guard result.status == 1, result.output.contains("No browser tab \(id) in this session") else { fail("browser screenshot escaped its session") }
        }
        let unparented = await berth("tabs", asOutsider: true)
        guard unparented.status == 1, unparented.output.contains("Only a Claude session tab") else { fail("browser allowed a shell without a Claude parent") }
        guard tall.loadedWebView == nil else { fail("background browser tab should start unloaded") }

        let plainURL = folder.appending(path: "plain.png")
        let plain = await berth("screenshot", "--tab", tallID, "--out", plainURL.path)
        guard plain.status == 0, plain.output == plainURL.path,
              let bitmap = try NSBitmapImageRep(data: Data(contentsOf: plainURL)),
              let pixel = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 4)?.usingColorSpace(.deviceRGB),
              pixel.redComponent > pixel.blueComponent + 0.25, tall.loadedWebView?.window == nil
        else { fail("background browser screenshot should paint the page and detach") }

        let fullURL = folder.appending(path: "full.png")
        let full = await berth("screenshot", "--tab", tallID, "--out", fullURL.path, "--full-page")
        guard full.status == 0, full.output == fullURL.path,
              let fullBitmap = try NSBitmapImageRep(data: Data(contentsOf: fullURL)), fullBitmap.pixelsHigh > bitmap.pixelsHigh,
              let bottom = fullBitmap.colorAt(x: fullBitmap.pixelsWide / 2, y: fullBitmap.pixelsHigh * 98 / 100)?.usingColorSpace(.deviceRGB),
              bottom.greenComponent > bottom.blueComponent + 0.25
        else { fail("full-page browser screenshot should include the bottom of the document") }

        print("browser screenshot height \(bitmap.pixelsHigh), full page \(fullBitmap.pixelsHigh)")

        let text = await berth("text")
        guard text.status == 0, text.output.contains("Browser control fixture text") else { fail("browser text should read the active page") }

        let console = await berth("console", "--json")
        let entries = try JSONDecoder().decode(ControlResponse.self, from: Data(console.output.utf8)).console ?? []
        guard console.status == 0,
              let warning = entries.first(where: { $0.level == "warn" && $0.text.contains("control fixture warning") }),
              entries.contains(where: { $0.level == "log" && $0.text.contains("control fixture log") }),
              entries.contains(where: { $0.level == "error" && $0.text.contains("control fixture error") }),
              entries.contains(where: { $0.level == "error" && $0.text.contains("control fixture uncaught") })
        else { fail("browser console should capture log, warn, error and uncaught error") }

        let since = await berth("console", "--since", String(warning.sequence), "--json")
        let filtered = try JSONDecoder().decode(ControlResponse.self, from: Data(since.output.utf8)).console
        guard since.status == 0, filtered == entries.filter({ $0.sequence > warning.sequence }) else { fail("browser console --since should filter by sequence") }

        let url = await berth("url")
        guard url.status == 0, url.output == loggedPage.absoluteString else { fail("browser url should print the file URL") }

        browser.select(pinned, in: key)
        let fallback = await berth("url")
        browser.select(active, in: key)
        guard fallback.status == 0, fallback.output == loggedPage.absoluteString else { fail("browser url should fall back to the last session tab when a pinned tab is selected") }

        let reload = await berth("reload")
        guard reload.status == 0 else { fail("browser reload should succeed") }

        let rejected = await berth("navigate", loggedPage.absoluteString)
        guard rejected.status == 2, rejected.output.contains("Pass one http or https URL") else { fail("browser navigate should reject a file URL") }

        let accepted = await berth("navigate", "https://example.invalid/", "--tab", tallID)
        guard accepted.status == 0 else { fail("browser navigate should accept an HTTPS URL") }
    }
}
#endif
