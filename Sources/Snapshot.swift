import BerthCore
import AppKit
import SwiftUI

enum Snapshot {
    #if DEBUG
    static let output = UserDefaults.standard.string(forKey: "snapshot").map { URL(filePath: $0) }
    #else
    static let output: URL? = nil
    #endif

    #if DEBUG
    static let forcesPulse = UserDefaults.standard.bool(forKey: "snapshotPulse")
    #else
    static let forcesPulse = false
    #endif

    #if DEBUG
    static let scrollsToArchive = UserDefaults.standard.integer(forKey: "snapshotArchiveRow") > 0
    #else
    static let scrollsToArchive = false
    #endif

    static func forcedSelection(in groups: [SessionGroup]) -> SidebarItem? {
        #if DEBUG
        let index = UserDefaults.standard.integer(forKey: "snapshotSelectRow")
        guard index > 0, let sessions = groups.first(where: { !$0.sessions.isEmpty })?.sessions, index <= sessions.count else { return nil }
        return .session(sessions[index - 1].id)
        #else
        return nil
        #endif
    }

    #if DEBUG
    static let launcherQuery = UserDefaults.standard.string(forKey: "snapshotLauncher") ?? ""
    #else
    static let launcherQuery = ""
    #endif

    #if DEBUG
    static let forcedHover = Set((UserDefaults.standard.string(forKey: "snapshotHover") ?? "").split(separator: "|").map(String.init))
    #else
    static let forcedHover: Set<String> = []
    #endif

    static func capture(to output: URL, store: Store) async {
        #if DEBUG
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let path = UserDefaults.standard.string(forKey: "snapshotCustomGroups"), let data = FileManager.default.contents(atPath: path) {
            store.customGroups = (try? JSONDecoder().decode([CustomGroup].self, from: data)) ?? []
        }
        await store.waitForScan()
        if UserDefaults.standard.bool(forKey: "snapshotShell") {
            try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "berth-shell-starts")
            store.openShell(cwd: store.activeSessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
            store.openShell(cwd: store.activeSessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path, command: "/bin/zsh -c 'printf \"\\033]2;npm run dev\\007\"; echo VITE ready; echo started >> \(NSTemporaryDirectory())berth-shell-starts; sleep 600'")
        }
        if let path = UserDefaults.standard.string(forKey: "snapshotShellCd"), let shell = store.shells.first {
            Task {
                try? await Task.sleep(for: .seconds(2))
                _ = shell.terminal.paste(text: "cd \(path)")
                _ = shell.terminal.sendKey(.enter)
            }
        }
        if UserDefaults.standard.bool(forKey: "snapshotTogglePanel") {
            try? await Task.sleep(for: .seconds(2))
            store.toggleTerminalPanel()
            try? await Task.sleep(for: .seconds(1))
            store.toggleTerminalPanel()
        }
        let archiveRow = UserDefaults.standard.integer(forKey: "snapshotArchiveRow")
        if archiveRow > 0, let sessions = store.groups.first(where: { !$0.sessions.isEmpty })?.sessions, archiveRow <= sessions.count {
            store.archive(sessions[archiveRow - 1].id)
        }
        if let sessionID = UserDefaults.standard.string(forKey: "snapshotResume") {
            store.activate(.session(sessionID))
        }
        if let cwd = UserDefaults.standard.string(forKey: "snapshotClaude") {
            store.openClaude(cwd: cwd, prompt: UserDefaults.standard.string(forKey: "snapshotPrompt") ?? "")
        }
        store.isLauncherPresented = UserDefaults.standard.string(forKey: "snapshotLauncher") != nil
        let editedGroup = UserDefaults.standard.string(forKey: "snapshotEditGroup").map { name in
            store.customGroups.first { $0.name == name } ?? CustomGroup(name: "", rules: [])
        }
        let root = editedGroup.map { AnyView(GroupEditor(group: $0).environment(\.ghosttyTheme, store.theme).preferredColorScheme(store.theme.isDark ? .dark : .light)) } ?? AnyView(ContentView())
        let hosting = NSHostingController(rootView: root.environment(store))
        hosting.sceneBridgingOptions = .all
        let window = UnconstrainedWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(editedGroup == nil ? NSSize(width: 1200, height: 760) : hosting.view.fittingSize)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(UserDefaults.standard.string(forKey: "snapshotClaude") == nil && UserDefaults.standard.string(forKey: "snapshotResume") == nil ? 3 : 10))
        try? await Task.sleep(for: .seconds(UserDefaults.standard.integer(forKey: "snapshotHold")))
        if UserDefaults.standard.bool(forKey: "snapshotToggleFrames") {
            for phase in ["hide", "show"] {
                let start = ContinuousClock.now
                store.toggleTerminalPanel()
                for frame in 0..<12 {
                    try? await Task.sleep(until: start + .milliseconds(frame * 40))
                    guard let image = image(of: window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                    try? png.write(to: output.deletingPathExtension().appendingPathExtension("\(phase)-\(frame * 40)ms.png"))
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "snapshotCloseTabs") {
            let processes = ProcessAncestry.descendants()
            print("before close: \(processes.map(\.pid).sorted())")
            for tab in store.tabs + store.shells { store.close(tab.id) }
            try? await Task.sleep(for: .seconds(3))
            print("alive after close: \(processes.map(\.pid).filter { kill($0, 0) == 0 }.sorted())")
        }
        let tab = store.tabs.first { $0.id == store.selectedTabID }
        window.title = tab.map { $0.title(terminalTitle: $0.terminal.title, sessionTitle: store.sessionTitle(of: $0)) } ?? "Berth"
        try? await Task.sleep(for: .milliseconds(500))
        let items = window.toolbar?.items.map { "\($0.itemIdentifier.rawValue) label=\($0.label) tip=\($0.toolTip ?? "")" } ?? []
        print("window title: \(window.title) | subtitle: \(window.subtitle)")
        print("toolbar items (\(items.count)):\n" + items.joined(separator: "\n"))
        let menus = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu) + (window.toolbar?.items ?? []).compactMap { ($0 as? NSMenuToolbarItem)?.menu }
        for menu in menus where menu.items.contains(where: { $0.title.hasPrefix("Group By") || $0.title.hasPrefix("New ") }) {
            print("menu \(menu.title):")
            for item in menu.items + menu.items.compactMap(\.submenu).flatMap(\.items) where !item.isSeparatorItem {
                print("  \(item.state == .on ? "✓" : " ") \(item.title) \(item.keyEquivalentModifierMask.contains(.control) ? "⌃" : "")\(item.keyEquivalent)")
            }
        }
        print("shell starts: \((try? String(contentsOfFile: NSTemporaryDirectory() + "berth-shell-starts", encoding: .utf8))?.split(separator: "\n").count ?? 0)")
        for tab in store.tabs + store.shells { print("tab \(tab.kind) cwd=\(tab.cwd) session=\(tab.sessionID ?? "-") pwd=\(tab.terminal.workingDirectory ?? "-") title=\(tab.terminal.title)") }
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { fail("window is on screen") }
        guard let image = image(of: window) else { fail("window capture failed: number \(window.windowNumber) visible \(window.isVisible) frame \(window.frame)") }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: output)) != nil
        else { fail("could not write \(output.path)") }
        ProcessAncestry.hangUpDescendants()
        exit(0)
        #endif
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

private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
