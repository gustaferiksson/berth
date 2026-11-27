#if DEBUG
import AppKit
import BerthCore
import SwiftUI

extension Snapshot {
    static let terminalCloseClickTarget = output != nil && UserDefaults.standard.bool(forKey: "snapshotTerminalCloseClicks") ? UUID() : nil
    static let sidebarHoverTarget = output != nil && UserDefaults.standard.bool(forKey: "snapshotSidebarHover") ? UUID() : nil
    static var closeFixtureTarget: UUID? { terminalCloseClickTarget ?? sidebarHoverTarget }
    static var terminalCloseFrame: CGRect?

    static func validateTerminalCloseClicks() {
        guard closeFixtureTarget != nil else { return }
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty,
              UserDefaults.standard.bool(forKey: "snapshotShell")
        else { fail("-snapshotTerminalCloseClicks and -snapshotSidebarHover need -snapshotShell YES and CFFIXED_USER_HOME pointing at an empty fixture home") }
    }

    static func prepareShellFixture(store: Store) {
        let cwd = store.activeSessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        store.openShell(cwd: cwd, command: closeFixtureTarget == nil ? nil : "/bin/zsh -f")
        store.openShell(cwd: cwd, command: "/bin/zsh -c 'printf \"\\033]2;npm run dev\\007\"; echo VITE ready; echo started >> \(NSTemporaryDirectory())berth-shell-starts; sleep 600'", id: closeFixtureTarget ?? UUID())
    }

    static func captureTerminalCloseClicks(target: Tab.ID, store: Store, window: NSWindow, output: URL) async {
        guard let view = window.contentView,
              store.terminals.count == 2, store.terminals.last?.id == target
        else { fail("expected two fixture terminals") }

        let offsets = [("centre", 0, 0)] + [4, 6, 11].flatMap { distance -> [(String, Int, Int)] in
            [
                ("left \(distance) pt", -distance, 0), ("right \(distance) pt", distance, 0),
                ("up \(distance) pt", 0, distance), ("down \(distance) pt", 0, -distance),
            ]
        } + [("top left corner", -11, 11), ("top right corner", 11, 11), ("bottom left corner", -11, -11), ("bottom right corner", 11, -11)]
        try? await Task.sleep(for: .seconds(2))
        store.activate(store.terminals.first.map { .tab($0.id) })
        try? await Task.sleep(for: .milliseconds(300))
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
              let image = image(of: window),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: output)) != nil
        else { fail("could not capture the terminal close fixture offscreen") }

        print("| Click | Result |")
        print("| --- | --- |")
        for (index, offset) in offsets.enumerated() {
            let (name, deltaX, deltaY) = offset
            guard let frame = terminalCloseFrame, !frame.isEmpty,
                  let selected = store.selectedTabID, selected != target
            else { fail("terminal close geometry \(String(describing: terminalCloseFrame)), target selected \(target == store.selectedTabID)") }

            let centre = view.convert(NSPoint(x: frame.midX, y: view.isFlipped ? frame.midY : view.bounds.maxY - frame.midY), to: nil)
            print("terminal close geometry \(frame), window centre \(centre), flipped \(view.isFlipped)")
            if index == 0 {
                for x in [centre.x - 11, centre.x + 7, centre.x + 11, centre.x + 16] {
                    let point = NSPoint(x: x, y: centre.y)
                    var hit = view.hitTest(view.superview?.convert(point, from: nil) ?? point)
                    while let candidate = hit, !(candidate is NSClipView) {
                        print("hit \(x) \(type(of: candidate)) \(candidate.convert(candidate.bounds, to: nil))")
                        hit = candidate.superview
                    }
                }
            }
            sendTerminalCloseClick(at: NSPoint(x: centre.x + CGFloat(deltaX), y: centre.y + CGFloat(deltaY)), in: window)
            try? await Task.sleep(for: .milliseconds(150))
            let result = if !store.tabs.contains(where: { $0.id == target }) {
                "closed"
            } else if store.selectedTabID != selected {
                "selected"
            } else {
                "nothing"
            }
            print("| \(name) | \(result) |")
            if index < offsets.count - 1 {
                for tab in store.terminals { store.close(tab.id) }
                terminalCloseFrame = nil
                try? await Task.sleep(for: .milliseconds(100))
                prepareShellFixture(store: store)
                try? await Task.sleep(for: .milliseconds(300))
                store.activate(store.terminals.first.map { .tab($0.id) })
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }

    private static func sendTerminalCloseClick(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { fail("could not create a terminal close mouse event") }

            window.sendEvent(event)
        }
    }
}

struct SnapshotTerminalCloseGeometry: ViewModifier {
    let hoverID: String

    func body(content: Content) -> some View {
        if hoverID == Snapshot.closeFixtureTarget?.uuidString {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Snapshot.terminalCloseFrame = $0 }
        } else {
            content
        }
    }
}
#endif
