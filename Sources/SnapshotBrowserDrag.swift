#if DEBUG
import AppKit
import SwiftUI

extension Snapshot {
    nonisolated(unsafe) static var tabFrames: [String: CGRect] = [:]

    static func recordTabFrame(_ frame: CGRect, for title: String) {
        tabFrames[title] = frame
    }

    static func forcedDropEdge(for title: String) -> HorizontalEdge? {
        let parts = (UserDefaults.standard.string(forKey: "snapshotBrowserDropEdge") ?? "").split(separator: "|")
        guard parts.count == 2, parts[0] == title else { return nil }

        return parts[1] == "leading" ? .leading : .trailing
    }

    private struct DragStep {
        let name: String
        let moved: String
        let target: String
        let edge: HorizontalEdge
        let pinned: [String]
        let session: [String]
    }

    private static func drop(_ tab: BrowserTab, at point: NSPoint, in window: NSWindow) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("berth-tab-drag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let plainText = NSPasteboard.PasteboardType("public.plain-text")
        let data = NSPasteboard.PasteboardType("public.data")
        pasteboard.declareTypes([.string, plainText, data], owner: nil)
        pasteboard.setData(Data(tab.id.uuidString.utf8), forType: data)
        pasteboard.setString(tab.id.uuidString, forType: .string)
        pasteboard.setString(tab.id.uuidString, forType: plainText)
        var location = point
        let info = FakeDrag(pasteboard: pasteboard, location: point, window: window)
        // NSWindow's own draggingEntered: rejects a synthesized NSDraggingInfo, so this calls the destination lookup it uses.
        typealias DragHitTest = @convention(c) (NSView, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
        let dragHitTest = Selector(("_hitTest:dragTypes:"))
        let lookup = unsafeBitCast(frameView.method(for: dragHitTest), to: DragHitTest.self)
        let destination = lookup(frameView, dragHitTest, &location, NSSet(array: (pasteboard.types ?? []).map(\.rawValue)))
        guard let destination, !destination.draggingEntered(info).isEmpty else { return false }

        _ = destination.draggingUpdated(info)
        return destination.performDragOperation(info)
    }

    private static func write(_ window: NSWindow, to url: URL) {
        guard let image = image(of: window) else { return }

        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    static func probeTabDrag(store: Store, window: NSWindow, directory: URL) async {
        guard let key = store.browser.sessionKey else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tabs = Dictionary(uniqueKeysWithValues: (store.browser.pinned + store.browser.tabs(in: key)).map { ($0.displayTitle, $0) })
        let selectedID = store.browser.shownTab?.id
        let initialPinned = store.browser.pinned.map(\.displayTitle)
        let initialSession = store.browser.tabs(in: key).map(\.displayTitle)
        guard initialPinned.count == 2, initialSession.count == 4 else {
            print("browser tab drag FAIL: needs the default fixture, got pinned \(initialPinned), session \(initialSession)")
            return
        }

        let steps = [
            DragStep(name: "regular reorder", moved: initialSession[3], target: initialSession[1], edge: .leading, pinned: initialPinned, session: [initialSession[0], initialSession[3], initialSession[1], initialSession[2]]),
            DragStep(name: "pinned reorder", moved: initialPinned[0], target: initialPinned[1], edge: .trailing, pinned: [initialPinned[1], initialPinned[0]], session: [initialSession[0], initialSession[3], initialSession[1], initialSession[2]]),
            DragStep(name: "regular to pinned", moved: initialSession[2], target: initialPinned[1], edge: .leading, pinned: [initialSession[2], initialPinned[1], initialPinned[0]], session: [initialSession[0], initialSession[3], initialSession[1]]),
            DragStep(name: "pinned to regular", moved: initialPinned[0], target: initialSession[3], edge: .trailing, pinned: [initialSession[2], initialPinned[1]], session: [initialSession[0], initialSession[3], initialPinned[0], initialSession[1]]),
        ]
        try? await Task.sleep(for: .milliseconds(500))
        write(window, to: directory.appending(path: "0-before.png"))
        for (index, step) in steps.enumerated() {
            guard let moved = tabs[step.moved], let frame = tabFrames[step.target], let height = window.contentView?.bounds.height else {
                print("browser tab drag \(step.name) FAIL: no frame for \(step.target)")
                continue
            }

            let point = NSPoint(x: step.edge == .leading ? frame.minX + 3 : frame.maxX - 3, y: height - frame.midY)
            let performed = drop(moved, at: point, in: window)
            try? await Task.sleep(for: .milliseconds(600))
            let pinned = store.browser.pinned.map(\.displayTitle)
            let session = store.browser.tabs(in: key).map(\.displayTitle)
            let keepsSelection = store.browser.shownTab?.id == selectedID
            let passes = performed && pinned == step.pinned && session == step.session && keepsSelection
            print("browser tab drag \(step.name) \(passes ? "PASS" : "FAIL"): performed \(performed), pinned \(pinned), session \(session), selection kept \(keepsSelection)")
            write(window, to: directory.appending(path: "\(index + 1)-\(step.name.replacing(" ", with: "-")).png"))
        }
    }
}
#else
import SwiftUI

extension Snapshot {
    static func recordTabFrame(_: CGRect, for _: String) {}
    static func forcedDropEdge(for _: String) -> HorizontalEdge? { nil }
}
#endif
