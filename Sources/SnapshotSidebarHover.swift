#if DEBUG
import AppKit
import BerthCore
import SwiftUI

extension Snapshot {
    struct RowHoverSample {
        let time: ContinuousClock.Instant
        let isHighlighted: Bool
        let showsClose: Bool
    }

    static var rowHoverSamples: [RowHoverSample] = []
    static var hoverRowFrame: CGRect?

    static func captureSidebarHover(target: Tab.ID, store: Store, window: NSWindow) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("hover: FAIL timed out")
            exit(1)
        }
        guard let view = window.contentView, store.terminals.count == 2, store.terminals.last?.id == target
        else { fail("expected two fixture terminals") }

        try? await Task.sleep(for: .seconds(2))
        store.activate(store.terminals.first.map { .tab($0.id) })
        try? await Task.sleep(for: .milliseconds(300))
        guard let row = hoverRowFrame, !row.isEmpty else { print("hover: FAIL no row geometry"); exit(1) }

        let windowPoint = { (x: CGFloat, y: CGFloat) in view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.maxY - y), to: nil) }
        var pointerCell: NSView?
        let send = { (type: NSEvent.EventType, point: NSPoint, cell: NSView?) in
            let area = cell?.trackingAreas.first { $0.options.contains(.mouseMoved) }
            let trackingNumber = area.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
            let event = type == .mouseMoved
                ? NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                : NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: trackingNumber, userData: nil)
            guard let event else { fail("could not create a mouse event") }

            window.sendEvent(event)
        }
        let move = { (point: NSPoint) in
            let cell = hostingCell(under: point, in: view)
            if cell !== pointerCell {
                send(.mouseExited, point, pointerCell)
                send(.mouseEntered, point, cell)
                pointerCell = cell
            }
            send(.mouseMoved, point, cell)
        }

        move(windowPoint(row.minX - 30, row.midY))
        try? await Task.sleep(for: .milliseconds(200))
        rowHoverSamples = []
        let start = windowPoint(row.minX + 40, row.midY)
        let rowEnd = windowPoint(row.maxX - 30, row.midY)
        for step in 0...20 {
            move(NSPoint(x: start.x + (rowEnd.x - start.x) * CGFloat(step) / 20, y: start.y))
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard rowHoverSamples.last?.isHighlighted == true else { print("hover: not delivered, the synthetic pointer never highlighted the row"); exit(2) }
        guard let close = terminalCloseFrame, !close.isEmpty else { print("hover: FAIL no close button geometry"); exit(1) }

        let centre = windowPoint(close.midX, close.midY)
        for step in 1...10 {
            move(NSPoint(x: rowEnd.x + (centre.x - rowEnd.x) * CGFloat(step) / 10, y: centre.y))
            try? await Task.sleep(for: .milliseconds(16))
        }
        let holdStart = ContinuousClock.now
        for frame in 0..<60 {
            store.tabs = store.tabs
            move(NSPoint(x: centre.x + CGFloat(frame % 3) - 1, y: centre.y + CGFloat(frame % 2) - 0.5))
            try? await Task.sleep(for: .milliseconds(16))
        }

        let changesDuringHold = rowHoverSamples.count(where: { $0.time >= holdStart })
        let steady = rowHoverSamples.last.map { $0.isHighlighted && $0.showsClose } ?? false
        print("hover: row \(row), close \(close), \(rowHoverSamples.count) state changes, \(changesDuringHold) during the 1 s hold")
        for sample in rowHoverSamples { print("  +\((sample.time - holdStart).formatted()) highlighted \(sample.isHighlighted) close shown \(sample.showsClose)") }
        print("hover: steady while the pointer rests on the close button \(changesDuringHold == 0 && steady ? "PASS" : "FAIL")")

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { fail("could not create a mouse event") }

            window.sendEvent(event)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let closed = !store.tabs.contains { $0.id == target }
        print("hover: click on the close button closes the terminal \(closed ? "PASS" : "FAIL")")
        ProcessAncestry.hangUpDescendants()
        exit(changesDuringHold == 0 && steady && closed ? 0 : 1)
    }

    private static func hostingCell(under point: NSPoint, in view: NSView) -> NSView? {
        if String(describing: type(of: view)).hasPrefix("CellHostingView"), view.convert(view.bounds, to: nil).contains(point) { return view }
        for subview in view.subviews {
            if let found = hostingCell(under: point, in: subview) { return found }
        }
        return nil
    }
}

struct SnapshotRowHoverProbe: ViewModifier {
    let hoverID: String
    let isHighlighted: Bool
    let showsClose: Bool

    func body(content: Content) -> some View {
        if hoverID == Snapshot.sidebarHoverTarget?.uuidString {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { Snapshot.hoverRowFrame = $0 }
                .onChange(of: isHighlighted, initial: true) { record() }
                .onChange(of: showsClose) { record() }
        } else {
            content
        }
    }

    private func record() {
        Snapshot.rowHoverSamples.append(Snapshot.RowHoverSample(time: .now, isHighlighted: isHighlighted, showsClose: showsClose))
    }
}
#endif
