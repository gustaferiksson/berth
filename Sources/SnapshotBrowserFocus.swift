#if DEBUG
import AppKit
import BerthCore
import Foundation
import GhosttyTerminal

extension Snapshot {
    static let probesBrowserFocus = UserDefaults.standard.bool(forKey: "snapshotBrowserFocus")
    static let browserFocusPage = URL(string: "data:text/html;base64," + Data("""
    <!doctype html><title>Focus Fixture</title>
    <input id="first" autofocus><input id="second">
    """.utf8).base64EncodedString())!

    static func captureBrowserFocus(store: Store, window: NSWindow) async {
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              !home.isEmpty, UserDefaults.standard.bool(forKey: ControlService.enabledKey),
              store.isConversationEnabled
        else { fail("-snapshotBrowserFocus needs CFFIXED_USER_HOME, -controlEnabled YES and -conversationEnabled YES") }

        await store.browser.prepareSnapshotRules()
        guard store.browser.mayLoad else { fail("could not prepare local browser fixture rules") }

        let session = UUID()
        let other = UUID()
        store.openShell(cwd: home, command: "exec cat", id: session)
        guard let shell = store.tabs.first(where: { $0.id == session }) else { fail("missing fixture terminal") }

        store.openShell(cwd: home, command: "exec cat", id: other)
        store.tabs = store.tabs.map { Tab(id: $0.id, kind: .claude, cwd: home, sessionID: $0.id.uuidString, terminal: $0.terminal) }
        store.activate(.tab(session))
        store.browser.setAgentAccess(.allowed, for: session.uuidString)
        try? await Task.sleep(for: .milliseconds(500))
        guard let terminal = shell.terminal.attachedPlatformView, terminal.window === window,
              let content = window.contentView
        else { fail("fixture terminal did not mount") }

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        content.addSubview(text)
        var changed: [String] = []
        var caller = session
        func describe(_ responder: NSResponder?) -> String {
            responder.map { "\(type(of: $0)) \(ObjectIdentifier($0))" } ?? "nil"
        }

        func run(_ operation: ControlOp, label: String, responder: NSView, url: URL? = nil, target: String? = nil, text: String? = nil, error: String? = nil) async -> ControlResponse {
            guard window.makeFirstResponder(responder), window.firstResponder === responder else { fail("could not set responder for \(label)") }

            let isActive = NSApp.isActive
            let isKey = window.isKeyWindow
            let movement = BrowserFocusMovement()
            let observation = window.observe(\.firstResponder, options: [.new]) { _, change in
                MainActor.assumeIsolated {
                    if change.newValue.flatMap(\.self) !== responder { movement.changed = true }
                }
            }
            print("\(label) before \(describe(window.firstResponder)) active=\(isActive) key=\(isKey)")
            let request = ControlRequest(token: "", caller: caller.uuidString, operation: operation, text: text, url: url?.absoluteString, target: target)
            let response = await store.control.handle(request)
            try? await Task.sleep(for: .milliseconds(150))
            observation.invalidate()
            print("\(label) after  \(describe(window.firstResponder)) active=\(NSApp.isActive) key=\(window.isKeyWindow)")
            if movement.changed || window.firstResponder !== responder || NSApp.isActive != isActive || window.isKeyWindow != isKey { changed.append(label) }
            guard response.error == error else { fail("\(label) returned \(response.error ?? "success"), expected \(error ?? "success")") }

            return response
        }

        _ = await run(.openURL, label: "open-url terminal to Browser", responder: terminal, url: browserFocusPage)
        guard store.shownPane == .browser else { fail("open-url did not show the Browser pane") }

        store.hideSessionPanel()
        store.setConversation(true)
        try? await Task.sleep(for: .milliseconds(500))
        func composer(in view: NSView) -> ComposerTextView? {
            (view as? ComposerTextView) ?? view.subviews.lazy.compactMap { composer(in: $0) }.first
        }

        guard let field = composer(in: content) else { fail("fixture composer did not mount") }

        _ = await run(.browserOpen, label: "browser-open blank composer to Browser", responder: field)
        guard store.shownPane == .browser, store.browser.shownTab?.url == nil else { fail("browser-open did not show a blank Browser tab") }

        _ = await run(.openURL, label: "open-url missing URL", responder: text, error: "Pass one http or https URL")
        _ = await run(.openURL, label: "open-url with URL", responder: text, url: browserFocusPage)
        guard let page = store.browser.shownTab, page.webView.window === window else { fail("fixture web view did not mount") }

        _ = await run(.browserFill, label: "browser-fill", responder: field, target: "#first", text: "filled")
        _ = await run(.browserClick, label: "browser-click", responder: field, target: "#first")
        _ = await run(.browserType, label: "browser-type", responder: field, text: "-typed")
        _ = await run(.browserPress, label: "browser-press Tab", responder: field, text: "Tab")
        let result = await run(.browserEval, label: "browser-eval", responder: field, text: """
        const active = document.activeElement.id;
        const first = document.querySelector('#first');
        first.focus();
        return [first.value.replace('-typed', ''), first.value.includes('-typed'), active, document.activeElement.id];
        """)
        guard result.text == #"["filled",true,"second","first"]"# else { fail("fixture DOM focus or input did not update: \(result.text ?? "nil")") }

        _ = await run(.browserOpen, label: "browser-open while the current page has focus", responder: page.webView)
        guard store.browser.shownTab === page else { fail("browser-open replaced the focused page") }

        let active = await run(.browserURL, label: "browser-url for the new blank tab", responder: page.webView)
        guard active.text?.isEmpty == true else { fail("browser-url did not target the agent's new tab") }

        caller = other
        let approval = Task { await run(.openURL, label: "open-url with approval in another session", responder: field, url: browserFocusPage) }
        for _ in 0..<100 where store.browser.access.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let request = store.browser.access.requests.first, window.attachedSheet == nil, window.firstResponder === field else {
            fail("browser approval interrupted the composer")
        }

        store.browser.access.resolve(request, with: .allowed)
        _ = await approval.value
        guard store.selectedTabID == session, store.sessionPanes[other] == .browser else { fail("open-url displaced the current session") }
        guard changed.isEmpty else { fail("focus changed during \(changed.joined(separator: ", "))") }

        print("focus probe passed")
        store.isTerminating = true
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }
}

private final class BrowserFocusMovement {
    var changed = false
}
#endif
