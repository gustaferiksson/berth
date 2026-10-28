import AppKit
import SwiftUI

enum Snapshot {
    #if DEBUG
    static let output = UserDefaults.standard.string(forKey: "snapshot").map { URL(filePath: $0) }
    #else
    static let output: URL? = nil
    #endif

    static let offscreen = CGPoint(x: -10000, y: -10000)

    static func prepare() {
        #if DEBUG
        NSApp.setActivationPolicy(.accessory)
        let unconstrained: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, frame, _ in frame }
        for name in ["NSWindow", "SwiftUI.AppKitWindow"] {
            guard let type = NSClassFromString(name),
                  let method = class_getInstanceMethod(type, #selector(NSWindow.constrainFrameRect(_:to:)))
            else { continue }
            method_setImplementation(method, imp_implementationWithBlock(unconstrained))
        }
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        #endif
    }

    static func capture(to output: URL, store: Store) async {
        #if DEBUG
        let sceneWindow = await mainSceneWindow()
        guard !isOnScreen(sceneWindow) else {
            sceneWindow.orderOut(nil)
            fail("scene window opened on screen at \(sceneWindow.frame)")
        }
        await store.waitForScan()
        if UserDefaults.standard.bool(forKey: "snapshotShell") {
            store.openShell(cwd: store.groups.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
        }
        if let sessionID = UserDefaults.standard.string(forKey: "snapshotResume") {
            store.activate(.session(sessionID))
        }
        if let cwd = UserDefaults.standard.string(forKey: "snapshotClaude") {
            store.openClaude(cwd: cwd)
        }
        let window = UserDefaults.standard.bool(forKey: "snapshotHosted") ? hostedWindow(store: store, replacing: sceneWindow) : sceneWindow
        try? await Task.sleep(for: .seconds(UserDefaults.standard.string(forKey: "snapshotClaude") == nil && UserDefaults.standard.string(forKey: "snapshotResume") == nil ? 3 : 10))
        if window !== sceneWindow {
            let tab = store.tabs.first { $0.id == store.selectedTabID }
            window.title = tab.map { $0.title(terminalTitle: $0.terminal.title, sessionTitle: store.sessionTitle(of: $0)) } ?? "Berth"
            try? await Task.sleep(for: .milliseconds(500))
        }
        let items = window.toolbar?.items.map { "\($0.itemIdentifier.rawValue) label=\($0.label) tip=\($0.toolTip ?? "")" } ?? []
        print("window title: \(window.title) | subtitle: \(window.subtitle)")
        print("toolbar items (\(items.count)):\n" + items.joined(separator: "\n"))
        for tab in store.tabs { print("tab \(tab.kind) cwd=\(tab.cwd) session=\(tab.sessionID ?? "-")") }
        guard !isOnScreen(window) else { fail("window is on screen") }
        guard let image = image(of: window) else { fail("window capture failed: number \(window.windowNumber) visible \(window.isVisible) frame \(window.frame)") }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: output)) != nil
        else { fail("could not write \(output.path)") }
        ProcessAncestry.hangUpDescendants()
        exit(0)
        #endif
    }

    private static func mainSceneWindow() async -> NSWindow {
        while true {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) { return window }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    // The offscreen scene window draws the glass sidebar with its contents blurred, so this plain hosted window is for reading sidebar content.
    private static func hostedWindow(store: Store, replacing sceneWindow: NSWindow) -> NSWindow {
        sceneWindow.orderOut(nil)
        let hosting = NSHostingController(rootView: ContentView().environment(store))
        hosting.sceneBridgingOptions = .all
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.setFrameOrigin(offscreen)
        window.orderFrontRegardless()
        return window
    }

    private static func fail(_ message: String) -> Never {
        ProcessAncestry.hangUpDescendants()
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(1)
    }

    // cacheDisplay skips Liquid Glass and Metal; CGWindowListCreateImage is SDK-obsoleted but still exported and captures own windows without Screen Recording.
    private static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}
