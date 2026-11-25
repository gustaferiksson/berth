#if DEBUG
import AppKit
import Foundation
import GhosttyTerminal

extension Snapshot {
    static func capturePaneTerminal(store: Store, window: NSWindow, output: URL) async {
        try? await Task.sleep(for: .seconds(2))
        guard let session = store.sessionTab, let tab = store.paneTerminal(of: session.id), store.shownPane == .terminal else { fail("no pane terminal is shown") }

        for width in [1500.0, 1000.0, 1400.0] {
            window.setContentSize(NSSize(width: width, height: 900))
            try? await Task.sleep(for: .seconds(1.5))
            _ = tab.terminal.paste(text: "stty size; echo cols=$COLUMNS typed-at-\(Int(width))")
            _ = tab.terminal.sendKey(.enter)
            try? await Task.sleep(for: .seconds(1))
            let surface = tab.terminal.attachedPlatformView
            let frame = surface.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none"
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let split = descendants(window.contentView ?? NSView()).first { $0.identifier?.rawValue == "terminalSplit" } as? NSSplitView
            print("split \(split?.arrangedSubviews.map { "\(Int($0.frame.minX))+\(Int($0.frame.width))\(split?.isSubviewCollapsed($0) == true ? " collapsed" : "")" } ?? []), surface in window x \(surface.map { Int($0.convert($0.bounds, to: nil).minX) } ?? -1)")
            print("pane terminal at \(Int(width)): surface \(frame), first responder is surface \(window.firstResponder === surface), visible \(tab.terminal.isSurfaceVisible)")
            guard let image = image(of: window),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: output.path + ".pane-\(Int(width)).png"))) != nil
            else { fail("could not capture the pane terminal offscreen") }
        }
        await captureFind(in: tab, store: store, window: window, output: output)
    }

    private static func captureFind(in tab: Tab, store: Store, window: NSWindow, output: URL) async {
        let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
        let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
        method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
        method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
        window.makeFirstResponder(tab.terminal.attachedPlatformView)
        _ = tab.terminal.paste(text: "printf 'alpha\\nbeta\\nalpha\\n'")
        _ = tab.terminal.sendKey(.enter)
        try? await Task.sleep(for: .seconds(1))
        if let session = store.sessionTab { store.selectedTabID = session.id }
        window.makeFirstResponder(tab.terminal.attachedPlatformView)
        print("find target: selected is pane terminal \(store.selectedTabID == tab.id), focused is pane terminal \(store.focusedTerminal === tab.terminal)")
        let press = { (characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) in
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }

            window.sendEvent(event)
        }
        AppAction.findInTerminal.perform(on: store)
        try? await Task.sleep(for: .milliseconds(500))
        print("find opened: bar \(store.terminalSearch != nil), on pane terminal \(store.isSearchingPaneTerminal)")
        for character in "alpha" { press(String(character), 0, []) }
        try? await Task.sleep(for: .seconds(1))
        print("typed: total \(store.terminalSearch?.total.map(String.init) ?? "nil"), selected \(store.terminalSearch?.selected.map(String.init) ?? "nil")")
        tab.terminal.performBindingAction("navigate_search:next")
        try? await Task.sleep(for: .milliseconds(500))
        print("after next: selected \(store.terminalSearch?.selected.map(String.init) ?? "nil")")
        if let image = image(of: window) { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + ".pane-find.png")) }
        press("\u{1B}", 53, [])
        try? await Task.sleep(for: .milliseconds(500))
        print("after esc: bar \(store.terminalSearch == nil ? "closed" : "open")")
    }
}
#endif
