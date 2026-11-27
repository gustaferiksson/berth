import AppKit
import BerthCore
import os
import SwiftUI

let composerLog = Logger(subsystem: "dev.gustaf.berth", category: "composer")

struct ConversationComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let color: NSColor
    let hidesBang: Bool
    let rendersImageTags: Bool
    let focusRequest: Int
    let layoutWidth: CGFloat
    let slashPicker: ConversationSlashPicker?
    let shellCompleter: ConversationShellCompleter?
    let submit: () -> Void
    let attach: ([URL]) -> String
    let recall: () -> Bool
    let leaveShell: () -> Void

    private static let maxLines = 8.0

    static func height(of text: String, font: NSFont, width: CGFloat, rendersImageTags: Bool) -> CGFloat {
        let attributed = ComposerTextView.attributed(text, font: font, color: .textColor, rendersImageTags: rendersImageTags)
        return height(of: attributed, font: font, width: width)
    }

    private static func height(of text: NSAttributedString, font: NSFont, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let lineHeight = ceil(layout.defaultLineHeight(for: font))
        return min(max(ceil(layout.usedRect(for: container).height), lineHeight), lineHeight * maxLines)
    }

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
        textView.autoresizingMask = []
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
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
        let hasMarkedText = textView.hasMarkedText()
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }
        if !hasMarkedText, textView.font != font {
            textView.font = font
            textView.needsDisplay = true
        }
        if !hasMarkedText, textView.textColor != color { textView.textColor = color }
        textView.insertionPointColor = color
        textView.onSubmit = submit
        textView.onAttach = attach
        textView.onRecall = recall
        textView.onLeaveShell = leaveShell
        textView.hiddenPrefix = hidesBang ? "!" : ""
        let pickerChanged = textView.slashPicker !== slashPicker || textView.shellCompleter !== shellCompleter
        textView.slashPicker = slashPicker
        slashPicker?.field = textView
        textView.shellCompleter = shellCompleter
        shellCompleter?.field = textView
        let imageTagsChanged = textView.rendersImageTags != rendersImageTags
        let textChanged = !hasMarkedText && textView.draftText != text
        let draftChanged = !hasMarkedText && (imageTagsChanged || textChanged)
        if draftChanged {
            let oldSelection = textView.selectedRange()
            let oldLength = textView.string.utf16.count
            context.coordinator.isUpdatingText = true
            defer { context.coordinator.isUpdatingText = false }
            textView.rendersImageTags = rendersImageTags
            let attributed = textView.attributed(text)
            textView.textStorage?.setAttributedString(attributed)
            if text.isEmpty { scrollView.contentView.scroll(to: .zero) }
            textView.setSelectedRange(NSRange(location: attributed.length, length: 0))
            composerLog.info("reset caret \(oldSelection.location, privacy: .public) to \(textView.selectedRange().location, privacy: .public), text length \(oldLength, privacy: .public) to \(attributed.length, privacy: .public), rendersImageTags changed \(imageTagsChanged, privacy: .public), text changed \(textChanged, privacy: .public)")
            textView.needsDisplay = true
        }
        if pickerChanged || draftChanged {
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }

                textView.refreshCompletions()
            }
        }
        guard focusRequest != context.coordinator.focusRequest else { return }

        context.coordinator.focusRequest = focusRequest
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? ComposerTextView, let layout = textView.textLayoutManager else { return nil }

        let width = layoutWidth > 0 ? layoutWidth : proposal.width ?? 400
        textView.frame.size.width = width
        layout.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer.height
        let height = Self.height(of: textView.attributedString(), font: font, width: width)
        let heightChanged = context.coordinator.height != height
        context.coordinator.height = height
        if heightChanged, textView.selectedRange().location == (textView.string as NSString).length {
            nsView.contentView.scroll(to: NSPoint(x: 0, y: max(0, used - height)))
        }
        return CGSize(width: proposal.width ?? width, height: min(height, proposal.height ?? height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConversationComposerField
        var focusRequest = 0
        var height: CGFloat = 0
        var isUpdatingText = false

        init(_ parent: ConversationComposerField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingText, let textView = notification.object as? ComposerTextView, !textView.hasMarkedText() else { return }

            parent.text = textView.draftText
            textView.refreshCompletions()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdatingText, let textView = notification.object as? ComposerTextView else { return }

            textView.refreshCompletions()
        }
    }
}

private final nonisolated class ComposerImageAttachment: NSTextAttachment {
    let token: String

    @MainActor
    init?(token: String, number: Int, scale: CGFloat, displayScale: CGFloat) {
        let tag = ConversationImageTag(number: number, scale: scale)
        guard let image = tag.image(displayScale: displayScale) else { return nil }

        self.token = token
        super.init(data: nil, ofType: nil)
        self.image = image
        bounds = NSRect(origin: NSPoint(x: 0, y: tag.baselineOffset), size: image.size)
    }

    required init?(coder _: NSCoder) {
        nil
    }
}

final class ComposerTextView: NSTextView {
    private static let attachmentCharacter = "\u{FFFC}"

    var placeholder = ""
    var onSubmit: () -> Void = {}
    var onAttach: ([URL]) -> String = { _ in "" }
    var onRecall: () -> Bool = { false }
    var onLeaveShell: () -> Void = {}
    var hiddenPrefix = ""
    var rendersImageTags = true
    weak var slashPicker: ConversationSlashPicker?
    weak var shellCompleter: ConversationShellCompleter?

    var draftText: String {
        guard let textStorage else { return string }

        return plainText(in: textStorage, range: NSRange(location: 0, length: textStorage.length))
    }

    private func plainText(in attributed: NSAttributedString, range: NSRange) -> String {
        let text = attributed.string as NSString
        var result = ""
        attributed.enumerateAttribute(.attachment, in: range) { attachment, run, _ in
            let value = text.substring(with: run)
            result += (attachment as? ComposerImageAttachment).map { value.replacing(Self.attachmentCharacter, with: $0.token) } ?? value
        }
        return result
    }

    func attributed(_ text: String) -> NSAttributedString {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return Self.attributed(text, font: font, color: textColor ?? .textColor, rendersImageTags: rendersImageTags, displayScale: window?.backingScaleFactor)
    }

    static func attributed(_ text: String, font: NSFont, color: NSColor, rendersImageTags: Bool, displayScale: CGFloat? = nil) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard rendersImageTags else { return NSAttributedString(string: text, attributes: attributes) }

        let scale = font.pointSize / NSFont.systemFontSize
        let displayScale = displayScale ?? NSScreen.main?.backingScaleFactor ?? 2
        let result = NSMutableAttributedString()
        var start = text.startIndex
        for match in text.matches(of: PromptTextPart.imageToken) {
            guard let number = Int(match.output.1),
                  let attachment = ComposerImageAttachment(token: String(match.output.0), number: number, scale: scale, displayScale: displayScale) else { continue }

            result.append(NSAttributedString(string: String(text[start..<match.range.lowerBound]), attributes: attributes))
            result.append(NSAttributedString(attachment: attachment, attributes: attributes))
            start = match.range.upperBound
        }
        result.append(NSAttributedString(string: String(text[start...]), attributes: attributes))
        return result
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let textStorage else { return false }

        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return false }

        return pasteboard.setString(ranges.map { plainText(in: textStorage, range: $0) }.joined(separator: "\n"), forType: .string)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, rendersImageTags, !hasMarkedText(), selectedRanges.count == 1, let text = pasteboard.string(forType: type), text.contains("[Image #") else { return super.readSelection(from: pasteboard, type: type) }

        let replacement = attributed(text)
        guard replacement.containsAttachments(in: NSRange(location: 0, length: replacement.length)) else { return super.readSelection(from: pasteboard, type: type) }

        insertText(replacement, replacementRange: selectedRange())
        return true
    }

    var slashCompletion: (query: String, replacementRange: NSRange)? {
        let selection = selectedRange()
        let text = string.replacing(Self.attachmentCharacter, with: "\t")
        guard !hasMarkedText(), selection.length == 0, let caret = Range(selection, in: text)?.lowerBound,
              let token = SlashToken.find(in: text, caret: caret) else { return nil }

        return (token.query, NSRange(token.replacing, in: text))
    }

    func refreshCompletions() {
        slashPicker?.update(query: slashCompletion?.query)
        guard let shellCompleter, !hasMarkedText(), selectedRange().length == 0 else { return }

        shellCompleter.update(draft: hiddenPrefix + string, caret: selectedRange().location + hiddenPrefix.utf16.count)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let font else { return }

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.placeholderTextColor]
        placeholder.draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y), withAttributes: attributes)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard let scrollView = enclosingScrollView, let layout = textLayoutManager, NSMaxRange(range) == (string as NSString).length else { return super.scrollRangeToVisible(range) }

        layout.ensureLayout(for: layout.documentRange)
        let viewport = scrollView.contentView.bounds.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, layout.usageBoundsForTextContainer.height - viewport)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), !hiddenPrefix.isEmpty, selectedRange() == NSRange(location: 0, length: 0) else { return super.deleteBackward(sender) }

        onLeaveShell()
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshCompletions()
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        refreshCompletions()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else { return super.keyDown(with: event) }

        let isUnmodified = event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let submits = isReturn && event.modifierFlags.isDisjoint(with: [.shift, .option])
        if let slashPicker {
            slashPicker.update(query: slashCompletion?.query)
            if isUnmodified {
                if event.keyCode == 126, slashPicker.move(by: -1) { return }
                if event.keyCode == 125, slashPicker.move(by: 1) { return }
                if event.keyCode == 53, slashPicker.dismiss() { return }
            }
            if submits || isUnmodified && event.keyCode == 48, slashPicker.accept() { return }
        }
        if let shellCompleter, shellCompleter.isShowing, isUnmodified {
            if event.keyCode == 126, shellCompleter.move(by: -1) { return }
            if event.keyCode == 125, shellCompleter.move(by: 1) { return }
            if event.keyCode == 53, shellCompleter.dismiss() { return }
            if event.keyCode == 48 {
                _ = shellCompleter.accept()
                return
            }
        }
        if event.keyCode == 126, isUnmodified, string.isEmpty, onRecall() { return }
        guard isReturn else { return super.keyDown(with: event) }

        if submits {
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
        insertText(attributed((needsSpace ? " " : "") + tokens + " "), replacementRange: selectedRange())
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
