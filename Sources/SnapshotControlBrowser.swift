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
            try await probeControlBrowser(store: store, tool: tool, window: window, output: output)
            guard let image = image(of: window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fail("couldn’t capture the browser control window")
            }

            try png.write(to: output)
        } catch {
            fail(error.localizedDescription)
        }
        print("browser control probe passed")
        store.isTerminating = true
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }

    private static func probeControlBrowser(store: Store, tool: URL, window: NSWindow, output: URL) async throws {
        await store.browser.prepareSnapshotRules()
        let folder = FileManager.default.temporaryDirectory.appending(path: "berth-control-browser-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let loggedPage = folder.appending(path: "console.html")
        let tallPage = folder.appending(path: "tall.html")
        let simplePage = folder.appending(path: "simple.html")
        try Data("""
        <!doctype html><title>Control Console</title><h1>Browser control fixture text</h1>
        <form aria-label="Preferences">
          <label for="email">Email</label><input id="email" type="text" value="ada@example.com" required>
          <label for="controlled">Controlled</label><input id="controlled"><output id="controlled-output">Controlled: empty</output>
          <label for="region">Region</label><select id="region"><option value="eu">Europe</option><option value="na">North America</option></select>
          <label><input id="remember" type="checkbox" checked>Remember me</label>
          <button type="button" disabled>Save</button>
          <button>Submit</button><output id="submitted"></output>
          <a href="https://example.com/docs">Docs</a>
          <div>Plain fixture text</div>
        </form>
        <p id="hidden" hidden>Hidden fixture text</p>
        <button aria-hidden="true">Hidden fixture button</button>
        <button type="button" id="hover"><span>More info</span></button><output id="hovered"></output>
        <div id="editable" contenteditable="true">Old text</div>
        <div style="height:3000px"></div><a href="simple.html">Next fixture</a>
        <script>
        window.__berthRefs = new Map([['e1', document.body]]);
        const controlled = document.querySelector('#controlled');
        const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
        let tracker = '', appState = '';
        Object.defineProperty(controlled, 'value', {
          get() { return native.get.call(this); },
          set(value) { tracker = String(value); native.set.call(this, value); }
        });
        controlled.addEventListener('input', () => {
          if (controlled.value === tracker) return;
          appState = tracker = controlled.value;
          document.querySelector('#controlled-output').textContent = 'Controlled: ' + appState;
        });
        document.querySelector('form').addEventListener('submit', event => {
          event.preventDefault();
          document.querySelector('#submitted').textContent = 'Submitted: ' + JSON.stringify({
            email: document.querySelector('#email').value, controlled: appState,
            region: document.querySelector('#region').value, remember: document.querySelector('#remember').checked
          });
        });
        document.querySelector('#hover').addEventListener('mouseenter', () => {
          document.querySelector('#hovered').textContent = 'Hovered';
        });
        addEventListener('load', () => {
          console.log('control fixture log');
          console.warn('control fixture warning');
          console.error('control fixture error');
          setTimeout(() => { throw new Error('control fixture uncaught'); }, 0);
          Promise.reject('control fixture rejection');
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
        browser.setAgentAccess(.allowed, for: key)
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if active.webView.responds(to: selector) { active.webView.perform(selector, with: nil) }

        func berth(_ args: String..., appending extra: [String] = [], asOutsider: Bool = false) async -> (status: Int32, output: String) {
            let arguments = args + extra
            let result = await runControlCLI(tool, arguments: ["browser"] + arguments, environment: asOutsider ? store.control.environment(for: outsider) : environment)
            print("browser \(arguments.joined(separator: " ")) [\(result.status)] \(result.output)")
            return result
        }

        let activeID = String(active.id.uuidString.lowercased().prefix(8))
        let tallID = String(tall.id.uuidString.lowercased().prefix(8))
        let listed = await berth("tabs", "--json")
        let tabs = try JSONDecoder().decode(ControlResponse.self, from: Data(listed.output.utf8)).browserTabs
        guard listed.status == 0, tabs?.map(\.id) == [tallID, activeID], tabs?.filter(\.active).map(\.id) == [activeID] else {
            fail("browser tabs should list the caller’s two session tabs")
        }

        for denied in [pinned.id, other.id, UUID()] {
            let id = String(denied.uuidString.lowercased().prefix(8))
            for command in [["screenshot"], ["html"], ["snapshot"], ["click", "button"], ["fill", "input", "test"], ["eval", "return document.title"]] {
                let result = await berth(appending: command + ["--tab", id])
                guard result.status == 1, result.output == "berth: No browser tab \(id) in this session" else { fail("browser \(command[0]) escaped its session") }
            }
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

        let snapshot = await berth("snapshot")
        let lines = snapshot.output.split(separator: "\n")
        guard snapshot.status == 0, snapshot.output.contains("- text: Plain fixture text"),
              !snapshot.output.contains("Hidden fixture")
        else { fail("browser snapshot should include visible fixture content") }

        let expected = [
            /- heading "Browser control fixture text" \[level=1\] \[ref=e[0-9]+\]/,
            /\x20{2}- textbox "Email" \[required\] \[ref=e[0-9]+\]: ada@example\.com/,
            /\x20{2}- checkbox "Remember me" \[checked\] \[ref=e[0-9]+\]/,
            /\x20{2}- button "Save" \[disabled\] \[ref=e[0-9]+\]/,
            /\x20{2}- link "Docs" \[ref=e[0-9]+\] \/url: https:\/\/example\.com\/docs/,
        ]
        for pattern in expected where !lines.contains(where: { $0.wholeMatch(of: pattern) != nil }) {
            fail("browser snapshot should include the form controls with roles, names, states and refs")
        }

        let heading = snapshot.output.firstMatch(of: #/(?<ref>e[0-9]+)\]/#)?.ref
        guard let heading,
              try await active.webView.evaluateJavaScript("window.__berthRefs.get('\(heading)') === document.querySelector('h1')", contentWorld: BrowserPageContent.world) as? Bool == true,
              try await active.webView.evaluateJavaScript("""
              const button = document.createElement('button');
              button.textContent = 'New fixture button';
              document.body.prepend(button);
              window.__berthRefs.size === 1 && window.__berthRefs.get('e1') === document.body
              """, contentWorld: .page) as? Bool == true
        else { fail("browser snapshot refs should resolve only in the isolated world") }

        let repeated = await berth("snapshot", "--tab", activeID, "--json")
        let repeatedText = try JSONDecoder().decode(ControlResponse.self, from: Data(repeated.output.utf8)).text
        let repeatedLines = repeatedText?.split(separator: "\n") ?? []
        guard repeated.status == 0, repeatedLines.dropFirst().elementsEqual(lines),
              repeatedLines.first?.wholeMatch(of: /- button "New fixture button" \[ref=e[0-9]+\]/) != nil
        else { fail("browser snapshot refs should stay stable when an element is inserted") }

        let html = await berth("html")
        guard html.status == 0, html.output.hasPrefix("<html>\n  <head>\n"),
              html.output.contains(#"<input id="email" type="text" value="ada@example.com" required="">"#),
              html.output.contains("<script>\nwindow.__berthRefs")
        else { fail("browser html should print the formatted DOM and preserve the script body") }

        let selectedHTML = await berth("html", "--selector", "form > input")
        guard selectedHTML.status == 0, selectedHTML.output.hasPrefix(#"<input id="email""#), !selectedHTML.output.contains("\n")
        else { fail("browser html --selector should print the first matching element") }

        let missingHTML = await berth("html", "--selector", "#missing")
        guard missingHTML.status == 1, missingHTML.output.contains("No element matches CSS selector") else { fail("browser html should report a missing element") }

        let invalidHTML = await berth("html", "--selector", "[")
        guard invalidHTML.status == 1, invalidHTML.output.contains("Invalid CSS selector") else { fail("browser html should report an invalid selector") }

        let console = await berth("console", "--json")
        let entries = try JSONDecoder().decode(ControlResponse.self, from: Data(console.output.utf8)).console ?? []
        guard console.status == 0,
              let warning = entries.first(where: { $0.level == "warn" && $0.text.contains("control fixture warning") }),
              entries.contains(where: { $0.level == "log" && $0.text.contains("control fixture log") }),
              entries.contains(where: { $0.level == "error" && $0.text == "control fixture error" })
        else { fail("browser console should capture log, warn and error") }

        // WebKit can mute uncaught exception messages from file URLs.
        guard entries.contains(where: { $0.level == "error" && ($0.text == "Script error." || $0.text == "Error: control fixture uncaught") }),
              entries.contains(where: { $0.level == "error" && $0.text == "Unhandled promise rejection: control fixture rejection" })
        else { fail("browser console should capture an uncaught exception and the exact rejection message") }

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

        try await probeBrowserInteractions({ await berth(appending: $0) }, first: loggedPage, second: simplePage)

        try await probeBrowserAccess(store: store, tool: tool, folder: folder, window: window, promptOutput: output.deletingPathExtension().appendingPathExtension("prompt.png"), session: (session.uuidString, environment, active))
        store.activate(.tab(session))
        store.showBrowserPane()
        browser.select(active, in: key)
        try await Task.sleep(for: .seconds(1))
    }

    private static func probeBrowserAccess(store: Store, tool: URL, folder: URL, window: NSWindow, promptOutput: URL, session main: (key: String, environment: [String: String], tab: BrowserTab)) async throws {
        let browser = store.browser
        let access = browser.access
        let denied = "berth: " + BrowserAccess.deniedMessage

        func setPolicy(_ policy: AgentBrowserPolicy) {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[BrowserAccess.policyKey] = policy.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }

        func newSession() -> (key: String, environment: [String: String]) {
            let id = UUID()
            let caller = UUID()
            store.openShell(cwd: folder.path, command: "exec cat", id: id)
            store.tabs = store.tabs.map { tab in
                guard tab.id == id else { return tab }

                return Tab(id: id, kind: .claude, cwd: folder.path, sessionID: id.uuidString, terminal: tab.terminal)
            }
            store.openShell(cwd: folder.path, command: "exec cat", id: caller, parent: id)
            return (id.uuidString, store.control.environment(for: caller))
        }

        func run(_ environment: [String: String], _ args: String...) async -> (status: Int32, output: String) {
            let result = await runControlCLI(tool, arguments: ["browser"] + args, environment: environment)
            print("browser access \(args.joined(separator: " ")) [\(result.status)] \(result.output)")
            return result
        }

        func prompt() async -> BrowserAccess.Request {
            for _ in 0..<100 {
                if let request = access.requests.first { return request }

                try? await Task.sleep(for: .milliseconds(100))
            }
            fail("the first browser command from a session should raise an approval prompt")
        }

        let approved = newSession()
        let waiting = Task { await run(approved.environment, "tabs") }
        let request = await prompt()
        try? await Task.sleep(for: .milliseconds(600))
        guard access.decisions[approved.key] == nil, access.requests.count == 1, request.key == approved.key else { fail("the command should wait for an answer") }
        guard window.attachedSheet == nil, let image = image(of: window),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            fail("could not capture the nonmodal approval prompt")
        }

        try png.write(to: promptOutput)
        access.resolve(request, with: .allowed)
        guard await waiting.value.status == 0, await run(approved.environment, "tabs").status == 0, access.requests.isEmpty else { fail("an approved session should run commands without another prompt") }

        let refused = newSession()
        let refusal = Task { await run(refused.environment, "tabs") }
        await access.resolve(prompt(), with: .denied)
        let first = await refusal.value
        let second = await run(refused.environment, "tabs")
        guard first.status == 1, first.output == denied, second.status == 1, second.output == denied, access.requests.isEmpty else { fail("a denied session should fail without prompting again") }

        browser.setAgentAccess(.allowed, for: refused.key)
        guard await run(refused.environment, "tabs").status == 0 else { fail("re-allowing a session should let its commands run") }

        BrowserAccess.promptTimeout = .milliseconds(300)
        let silent = newSession()
        let timedOut = await run(silent.environment, "tabs")
        BrowserAccess.promptTimeout = .seconds(120)
        guard timedOut.status == 1, timedOut.output == "berth: " + BrowserAccess.unansweredMessage, access.requests.isEmpty, access.decisions[silent.key] == nil else { fail("an unanswered prompt should time out") }
        guard main.tab.isDrivenByAgent else { fail("a tab the agent used should be marked") }

        browser.setAgentAccess(.denied, for: main.key)
        let mainTabID = String(main.tab.id.uuidString.lowercased().prefix(8))
        let revoked = await run(main.environment, "url", "--tab", mainTabID)
        guard !main.tab.isDrivenByAgent, revoked.status == 1, revoked.output == denied else { fail("revoking should clear the mark and refuse commands") }

        browser.setAgentAccess(.allowed, for: main.key)
        guard await run(main.environment, "url", "--tab", mainTabID).status == 0, main.tab.isDrivenByAgent else { fail("re-allowing should let the agent drive again") }

        setPolicy(.off)
        let off = await run(approved.environment, "tabs")
        guard off.status == 1, off.output == "berth: " + BrowserAccess.offMessage else { fail("Off should refuse every agent browser command") }

        setPolicy(.allow)
        let always = newSession()
        guard await run(always.environment, "tabs").status == 0, access.requests.isEmpty else { fail("Always allow should skip the prompt") }
    }

    private static func probeBrowserInteractions(_ berth: ([String]) async -> (status: Int32, output: String), first: URL, second: URL) async throws {
        func checked(_ args: String...) async -> String {
            let result = await berth(args)
            guard result.status == 0 else { fail("browser \(args[0]) failed: \(result.output)") }

            return result.output
        }

        let snapshot = await checked("snapshot")
        let lines = snapshot.split(separator: "\n")
        guard let email = lines.first(where: { $0.contains(#"- textbox "Email""#) })?.firstMatch(of: #/\[ref=(e[0-9]+)\]/#)?.1 else {
            fail("browser snapshot should report an email ref")
        }

        _ = await checked("fill", String(email), "berth")
        _ = await checked("fill", "#controlled", "tracked")
        guard await checked("text").contains("Controlled: tracked") else { fail("browser fill should bypass the controlled input instance setter") }

        _ = await checked("fill", "#editable", "New text")
        guard await checked("eval", "return document.querySelector('#editable').textContent") == #""New text""# else {
            fail("browser fill should replace contenteditable text")
        }

        _ = await checked("click", "#email")
        _ = await checked("press", "End")
        _ = await checked("type", "-typed")
        _ = await checked("press", "Tab")
        guard await checked("eval", "return document.activeElement.id") == #""controlled""# else { fail("browser press Tab should move focus") }

        _ = await checked("press", "Shift+Tab")
        guard await checked("eval", "return document.activeElement.id") == #""email""# else { fail("browser press Shift+Tab should move focus back") }

        _ = await checked("select", "#region", "North America")
        _ = await checked("click", "#remember")

        for (target, error) in [("text=Save", "disabled"), ("#hidden", "hidden"), ("[", "Invalid CSS selector")] {
            let result = await berth(["click", target])
            guard result.status == 1, result.output.contains(error) else { fail("browser click should refuse \(target)") }
        }

        _ = await checked("click", "#email")
        _ = await checked("press", "Enter")
        let state = #"{"email":"berth-typed","controlled":"tracked","region":"na","remember":false}"#
        guard try await checked("eval", "return document.querySelector('#submitted').textContent") == String(decoding: JSONEncoder().encode("Submitted: " + state), as: UTF8.self),
              await checked("text").contains("Submitted: " + state)
        else { fail("browser press Enter should submit the edited form") }

        let hover = await checked("hover", "text=More info")
        guard hover.contains(#"button \"More info\""#), hover.contains(#""navigated":false"#), await checked("text").contains("Hovered") else {
            fail("browser hover should prefer the button and send mouseenter")
        }

        let ambiguous = await checked("hover", "button:not([disabled])")
        guard ambiguous.contains("elements matched; used the first in document order") else { fail("browser should report ambiguous selectors") }

        _ = await checked("scroll", "--to", "bottom")
        guard let offset = await Double(checked("eval", "return scrollY")), offset > 0 else { fail("browser scroll should move the page") }

        _ = await checked("eval", "setTimeout(() => document.body.append('Wait fixture marker'), 700)")
        _ = await checked("wait", "--text", "Wait fixture marker")
        _ = await checked("wait", "--ms", "125")
        let timeout = await berth(["wait", "--url", "/missing", "--timeout", "0.15"])
        guard timeout.status == 1, timeout.output.contains(#"Timed out waiting for URL containing "/missing""#) else { fail("browser wait should time out with the wanted URL") }

        for (args, url) in [(["click", "text=Next fixture"], second), (["back"], first), (["forward"], second)] {
            let result = await berth(args)
            let outcome = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
            guard result.status == 0, outcome?["navigated"] as? Bool == true, outcome?["url"] as? String == url.absoluteString else {
                fail("browser \(args[0]) should report navigation to \(url.lastPathComponent)")
            }
        }
        let stale = await berth(["click", String(email)])
        guard stale.status == 1, stale.output.contains("Take a new snapshot") else { fail("browser click should report stale refs after navigation") }

        _ = await checked("wait", "p")
        _ = await checked("wait", "--load")
        let object = await checked("eval", "return {title: await Promise.resolve(document.title), count: document.querySelectorAll('p').length}")
        guard object == #"{"title":"Simple Fixture","count":1}"# else { fail("browser eval should return async results as JSON") }
        guard await checked("eval", "return undefined") == "null" else { fail("browser eval should convert undefined to null") }

        let cyclic = await berth(["eval", "const object = {}; object.self = object; return object"])
        let oversized = await berth(["eval", "return 'x'.repeat(100000)"])
        guard cyclic.status == 1, oversized.status == 1, oversized.output.contains("100000 characters") else { fail("browser eval should refuse unserialisable and oversized results") }

        _ = await checked("eval", "setTimeout(() => history.back(), 700)")
        let afterNavigation = await checked("wait", "#email")
        guard afterNavigation.contains(#""navigated":true"#), afterNavigation.contains(first.absoluteString) else {
            fail("browser wait should keep polling across navigation")
        }

        _ = await checked("open", "--background")
        guard await checked("url") == first.absoluteString else { fail("browser open --background should preserve the active tab") }

        _ = await checked("open")
        guard await checked("url").isEmpty else { fail("browser open should select a blank session tab") }
    }
}
#endif
