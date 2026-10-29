#if DEBUG
import AppKit

@MainActor
enum SettingsSnapshot {
    nonisolated static let output = UserDefaults.standard.string(forKey: "settingsSnapshot").map { URL(filePath: $0) }

    static func capture(to output: URL) async {
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        keepWindowsOffScreen()
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," })
        else { exit(1) }
        menu.performActionForItem(at: index)
        let window = await settingsWindow()
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            window.orderOut(nil)
            exit(1)
        }
        try? await Task.sleep(for: .seconds(1.5))
        guard let image = image(of: window) else { exit(1) }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output)
        exit(0)
    }

    static func keepWindowsOffScreen() {
        let unconstrained: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, frame, _ in frame }
        let noAutosave: @convention(block) (NSWindow, String) -> Bool = { _, _ in true }
        for (selector, block) in [(#selector(NSWindow.constrainFrameRect(_:to:)), unconstrained as Any), (#selector(NSWindow.setFrameAutosaveName(_:)), noAutosave as Any)] {
            guard let method = class_getInstanceMethod(NSWindow.self, selector) else { continue }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        for (original, replacement) in [
            (#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.offscreenMakeKeyAndOrderFront(_:))),
            (#selector(NSWindow.orderFront(_:)), #selector(NSWindow.offscreenOrderFront(_:))),
            (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.offscreenOrderFrontRegardless)),
        ] {
            guard let originalMethod = class_getInstanceMethod(NSWindow.self, original),
                  let replacementMethod = class_getInstanceMethod(NSWindow.self, replacement)
            else { continue }
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    // cacheDisplay skips Liquid Glass; CGWindowListCreateImage is SDK-obsoleted but still exported and captures own windows without Screen Recording.
    private static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }

    private static func settingsWindow() async -> NSWindow {
        while true {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) { return window }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

extension NSWindow {
    @objc fileprivate func offscreenMakeKeyAndOrderFront(_ sender: Any?) {
        setFrameOrigin(NSPoint(x: -10000, y: 0))
        offscreenMakeKeyAndOrderFront(sender)
    }

    @objc fileprivate func offscreenOrderFront(_ sender: Any?) {
        setFrameOrigin(NSPoint(x: -10000, y: 0))
        offscreenOrderFront(sender)
    }

    @objc fileprivate func offscreenOrderFrontRegardless() {
        setFrameOrigin(NSPoint(x: -10000, y: 0))
        offscreenOrderFrontRegardless()
    }
}
#endif
