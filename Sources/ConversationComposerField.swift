import AppKit
import SwiftUI

struct ConversationComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let color: NSColor
    let promptColor: NSColor?
    let focusRequest: Int
    let submit: () -> Void
    let attach: ([URL]) -> String

    private static let maxLines = 8.0

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.writingToolsBehavior = .none
        textView.setAccessibilityLabel("Message")
        textView.registerForDraggedTypes([.fileURL])

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }

        context.coordinator.parent = self
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if textView.font != font {
            textView.font = font
            textView.needsDisplay = true
        }
        textView.textColor = color
        textView.insertionPointColor = color
        textView.onSubmit = submit
        textView.onAttach = attach
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
        }
        if let promptColor, text.hasPrefix("!") {
            textView.textStorage?.addAttribute(.foregroundColor, value: promptColor, range: NSRange(location: 0, length: 1))
        }
        guard focusRequest != context.coordinator.focusRequest else { return }

        context.coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context _: Context) -> CGSize? {
        guard let textView = nsView.documentView as? ComposerTextView, let layout = textView.textLayoutManager else { return nil }

        let width = proposal.width ?? 400
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        textView.frame.size.width = width
        layout.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer.height
        let inset = textView.textContainerInset.height * 2
        let maxHeight = lineHeight * Self.maxLines
        nsView.hasVerticalScroller = used > maxHeight
        return CGSize(width: width, height: min(max(used, lineHeight), maxHeight) + inset)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConversationComposerField
        var focusRequest = 0

        init(_ parent: ConversationComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            parent.text = textView.string
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = ""
    var onSubmit: () -> Void = {}
    var onAttach: ([URL]) -> String = { _ in "" }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let font else { return }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y), withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, !hasMarkedText() else { return super.keyDown(with: event) }

        if event.modifierFlags.isDisjoint(with: [.shift, .option]) {
            onSubmit()
        } else {
            insertNewlineIgnoringFieldEditor(nil)
        }
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return insertTokens(for: urls)
        }
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard), let png = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]) else { return pasteAsPlainText(sender) }

        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "Berth")
            .appending(path: "ConversationAttachments/\(UUID().uuidString)")
        let file = folder.appending(path: "Pasted Image.png")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil, (try? png.write(to: file)) != nil else { return }

        insertTokens(for: [file])
    }

    private func insertTokens(for urls: [URL]) {
        let tokens = onAttach(urls)
        guard !tokens.isEmpty else { return }

        let caret = selectedRange().location
        let needsSpace = caret > 0 && !(string as NSString).substring(with: NSRange(location: caret - 1, length: 1)).allSatisfy(\.isWhitespace)
        insertText((needsSpace ? " " : "") + tokens + " ", replacementRange: selectedRange())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }

        insertTokens(for: urls)
        return true
    }

    private func fileURLs(in sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

struct ConversationDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let drop: ([URL]) -> Void

    func makeNSView(context _: Context) -> DropView {
        let view = DropView()
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ view: DropView, context _: Context) {
        view.onTarget = { isTargeted = $0 }
        view.onDrop = drop
    }

    final class DropView: NSView {
        var onTarget: (Bool) -> Void = { _ in }
        var onDrop: ([URL]) -> Void = { _ in }

        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard !files(in: sender).isEmpty else { return [] }

            onTarget(true)
            return .copy
        }

        override func draggingExited(_: (any NSDraggingInfo)?) {
            onTarget(false)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            onTarget(false)
            let urls = files(in: sender)
            guard !urls.isEmpty else { return false }

            onDrop(urls)
            return true
        }

        private func files(in sender: any NSDraggingInfo) -> [URL] {
            sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
    }
}
