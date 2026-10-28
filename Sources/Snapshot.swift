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
    static let launcherQuery = UserDefaults.standard.string(forKey: "snapshotLauncher") ?? UserDefaults.standard.string(forKey: "snapshotSearch") ?? ""
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
        if UserDefaults.standard.bool(forKey: "snapshotFakeWaiting") {
            for waiting in [false, true, true, false, true] {
                print("fake first session waiting: \(waiting)")
                store.fakeWaiting = waiting
                store.refreshLive()
            }
        }
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
        if UserDefaults.standard.bool(forKey: "snapshotArchiveTab") {
            for _ in 0..<2 { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
            store.tabs = store.shells.map { Tab(id: $0.id, kind: .claude, cwd: $0.cwd, sessionID: UUID().uuidString.lowercased(), terminal: $0.terminal) }
            store.selectedTabID = store.tabs.last?.id
            store.shells = []
            store.isPanelOpen = false
        }
        if let sessionID = UserDefaults.standard.string(forKey: "snapshotResume") {
            store.activate(.session(sessionID))
        }
        if let cwd = UserDefaults.standard.string(forKey: "snapshotClaude") {
            store.openClaude(cwd: cwd, prompt: UserDefaults.standard.string(forKey: "snapshotPrompt") ?? "")
        }
        if UserDefaults.standard.string(forKey: "snapshotLauncher") != nil { store.launcherMode = .newSession }
        if UserDefaults.standard.string(forKey: "snapshotSearch") != nil { store.launcherMode = .search }
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
        if let query = UserDefaults.standard.string(forKey: "snapshotSearch") {
            Task {
                let start = ContinuousClock.now
                let before = footprint()
                while store.searchIndexVersion == 0 || store.searchIndexing != nil { try? await Task.sleep(for: .milliseconds(50)) }
                print("search index: \(store.searchIndex.count) sessions in \(ContinuousClock.now - start), text \(store.searchIndex.textBytes / 1024) KB, footprint \(before / 1_048_576) → \(footprint() / 1_048_576) MB")
                let clock = ContinuousClock.now
                let hits = store.searchIndex.search(query, in: store.activeSessions + store.archivedSessions)
                print("search \(query.count) chars: \(hits.count) hits, snippets \(hits.map(\.snippets.count)), \(ContinuousClock.now - clock)")
            }
        }
        try? await Task.sleep(for: .seconds(UserDefaults.standard.string(forKey: "snapshotClaude") == nil && UserDefaults.standard.string(forKey: "snapshotResume") == nil ? 3 : 10))
        try? await Task.sleep(for: .seconds(UserDefaults.standard.integer(forKey: "snapshotHold")))
        let peekRow = UserDefaults.standard.integer(forKey: "snapshotPeekRow")
        if peekRow > 0, let sessions = store.groups.first(where: { !$0.sessions.isEmpty })?.sessions, peekRow <= sessions.count {
            guardOffScreenOrdering()
            store.peekedSessionID = sessions[peekRow - 1].id
            try? await Task.sleep(for: .seconds(1.5))
            printPeek(store: store)
            let keys: [String: (characters: String, code: UInt16)] = [
                "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
                "space": (" ", 49), "escape": ("\u{1b}", 53), "return": ("\r", 36),
            ]
            for name in (UserDefaults.standard.string(forKey: "snapshotPeekKeys") ?? "").split(separator: "|").map(String.init) {
                guard let key = keys[name] else { continue }
                let target = NSApp.keyWindow ?? window
                let modifiers: NSEvent.ModifierFlags = key.code >= 125 ? [.numericPad, .function] : []
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) else { continue }
                    target.sendEvent(event)
                }
                try? await Task.sleep(for: .seconds(1.5))
                print("key \(name) sent to \(type(of: target)):")
                printPeek(store: store)
            }
        }
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
        if UserDefaults.standard.bool(forKey: "snapshotArchiveTab") {
            for tab in [store.tabs.first { $0.id != store.selectedTabID }, store.tabs.first { $0.id == store.selectedTabID }].compactMap(\.self) {
                weak var view = tab.terminal.attachedPlatformView
                let kind = tab.id == store.selectedTabID ? "selected" : "background"
                if let view { window.makeFirstResponder(view) }
                try? await Task.sleep(for: .seconds(1))
                print("ptys before archive: \(ptys())")
                store.archive(tab.sessionID ?? "")
                try? await Task.sleep(for: .seconds(3))
                print("archived \(kind) tab: view freed \(view == nil), ptys \(ptys())")
            }
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
        printPeek(store: store)
        guard let image = image(of: window) else { fail("window capture failed: number \(window.windowNumber) visible \(window.isVisible) frame \(window.frame)") }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: output)) != nil
        else { fail("could not write \(output.path)") }
        ProcessAncestry.hangUpDescendants()
        exit(0)
        #endif
    }

    private static func printPeek(store: Store) {
        let row = store.groups.first { !$0.sessions.isEmpty }?.sessions.firstIndex { $0.id == store.peekedSessionID }
        print("peek row: \(row.map { "\($0 + 1)" } ?? "closed") messages: \(store.peekMessages?.map { "\($0.kind):\($0.text.count)" } ?? [])")
        for popover in NSApp.windows where popover.isVisible && String(describing: type(of: popover)).contains("Popover") {
            print("popover window frame \(popover.frame) key \(popover.isKeyWindow)")
        }
    }

    private static func guardOffScreenOrdering() {
        for (original, replacement) in [
            (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.offscreenOnlyOrder(_:relativeTo:))),
            (#selector(NSWindow.setFrame(_:display:)), #selector(NSWindow.offscreenOnlySetFrame(_:display:))),
        ] {
            guard let originalMethod = class_getInstanceMethod(NSWindow.self, original),
                  let replacementMethod = class_getInstanceMethod(NSWindow.self, replacement)
            else { fail("could not guard window ordering") }
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    // NSPopover clamps to a real screen when its anchor window is off screen, so the popover is moved next to the sidebar of the off-screen window.
    fileprivate static func offScreen(_ frame: NSRect, of window: NSWindow) -> NSRect {
        guard String(describing: type(of: window)).contains("Popover"), NSScreen.screens.contains(where: { $0.frame.intersects(frame) }),
              let host = NSApp.windows.first(where: { $0 is UnconstrainedWindow })?.frame
        else { return frame }
        return NSRect(x: host.minX + 300, y: max(host.minY + 16, host.maxY - 160 - frame.height), width: frame.width, height: frame.height)
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Int(info.phys_footprint)
    }

    private static func ptys() -> Int {
        let lsof = Process()
        let pipe = Pipe()
        lsof.executableURL = URL(filePath: "/usr/sbin/lsof")
        lsof.arguments = ["-p", "\(getpid())"]
        lsof.standardOutput = pipe
        try? lsof.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").filter { $0.contains("/dev/ptmx") }.count
    }

    fileprivate static func fail(_ message: String) -> Never {
        ProcessAncestry.hangUpDescendants()
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(1)
    }

    // cacheDisplay skips Liquid Glass and Metal; CGWindowListCreateImage is SDK-obsoleted but still exported and captures own windows without Screen Recording.
    private static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        guard !popovers.isEmpty else {
            return create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
        }
        typealias CreateImageFromArray = @convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let arraySymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        let ids = (popovers + [window]).map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = ids.withUnsafeBufferPointer { CFArrayCreate(nil, UnsafeMutablePointer(mutating: $0.baseAddress), $0.count, nil) }
        guard let array else { return nil }
        return unsafeBitCast(arraySymbol, to: CreateImageFromArray.self)(.null, array, [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}

extension NSWindow {
    @objc fileprivate func offscreenOnlySetFrame(_ rect: NSRect, display: Bool) {
        offscreenOnlySetFrame(Snapshot.offScreen(rect, of: self), display: display)
    }

    @objc fileprivate func offscreenOnlyOrder(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        setFrame(Snapshot.offScreen(frame, of: self), display: false)
        if place != .out, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            Snapshot.fail("\(type(of: self)) would order in on screen at \(frame)")
        }
        offscreenOnlyOrder(place, relativeTo: otherWindow)
    }
}

private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
