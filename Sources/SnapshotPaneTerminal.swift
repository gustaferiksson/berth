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
    }
}
#endif
