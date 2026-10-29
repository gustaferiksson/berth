import AppKit
import GhosttyTerminal

// AppKit picks a drag destination by registered types and ignores opacity, so a hidden tab stacked above the visible one would take the drop.
final class VisibleDropTerminalView: AppTerminalView {
    private lazy var dropTypes = registeredDraggedTypes

    override func setSurfaceVisible(_ visible: Bool) {
        super.setSurfaceVisible(visible)
        let types = dropTypes
        unregisterDraggedTypes()
        if visible { registerForDraggedTypes(types) }
    }
}
