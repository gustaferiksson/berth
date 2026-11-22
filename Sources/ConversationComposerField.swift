import AppKit
import SwiftUI

struct ConversationComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let color: NSColor
    let focusRequest: Int
    let submit: () -> Void
    let attach: ([URL]) -> Void

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
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }

        context.coordinator.parent = self
        textView.placeholder = placeholder
        textView.font = font
        textView.textColor = color
        textView.insertionPointColor = color
        textView.onSubmit = submit
        textView.onAttach = attach
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
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
        return CGSize(width: width, height: min(max(used, lineHeight), lineHeight * Self.maxLines) + inset)
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
    var onAttach: ([URL]) -> Void = { _ in }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }

        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y), withAttributes: attributes)
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
            return onAttach(urls)
        }
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard), let png = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]) else { return pasteAsPlainText(sender) }

        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "Berth")
            .appending(path: "ConversationAttachments/\(UUID().uuidString)")
        let file = folder.appending(path: "Pasted Image.png")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil, (try? png.write(to: file)) != nil else { return }

        onAttach([file])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }

        onAttach(urls)
        return true
    }

    private func fileURLs(in sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
