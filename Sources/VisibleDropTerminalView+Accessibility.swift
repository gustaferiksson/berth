import AppKit

// AX clients (VoiceOver, caret-anchored overlays) read the caret via kAXSelectedTextRange + kAXBoundsForRange.
extension VisibleDropTerminalView {
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        firstRect(forCharacterRange: range, actualRange: nil)
    }
}
