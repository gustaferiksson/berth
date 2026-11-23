import AppKit
import SwiftUI

struct ConversationTextView: NSViewRepresentable {
    let text: NSAttributedString

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    func makeNSView(context _: Context) -> ConversationNSTextView {
        let view = ConversationNSTextView(usingTextLayoutManager: true)
        view.configure()
        return view
    }

    func updateNSView(_ view: ConversationNSTextView, context _: Context) {
        view.theme = theme
        view.openURL = { openURL($0) }
        view.show(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ConversationNSTextView, context _: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        return CGSize(width: width, height: view.height(fitting: width))
    }
}

final class ConversationNSTextView: NSTextView, NSTextViewDelegate {
    var theme = GhosttyTheme(values: [:]) {
        didSet {
            guard theme != oldValue else { return }

            linkTextAttributes = [.foregroundColor: NSColor(theme.unread), .cursor: NSCursor.pointingHand]
            needsDisplay = true
        }
    }

    var openURL: (URL) -> Void = { _ in }

    private var source: NSAttributedString?
    private var hoveredBlock: Int?
    private var copiedBlock: Int?
    private var fitted: (width: CGFloat, height: CGFloat)?
    private var cachedBlocks: [Block]?

    func configure() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        delegate = self
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    override func writeSelection(to pasteboard: NSPasteboard, types _: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }

        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString((string as NSString).substring(with: range), forType: .string)
    }

    func show(_ text: NSAttributedString) {
        guard source !== text else { return }

        source = text
        guard textStorage?.isEqual(to: text) != true else { return }

        textStorage?.setAttributedString(text)
        hoveredBlock = nil
        copiedBlock = nil
        fitted = nil
        cachedBlocks = nil
        needsDisplay = true
    }

    func height(fitting width: CGFloat) -> CGFloat {
        if let fitted, fitted.width == width { return fitted.height }
        guard let textContainer, let manager = textLayoutManager else { return 0 }

        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: manager.documentRange)
        cachedBlocks = nil
        let height = ceil(max(manager.usageBoundsForTextContainer.maxY, blocks().map(\.rect.maxY).max() ?? 0))
        fitted = (width, height)
        return height
    }

    func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }

        openURL(url)
        return true
    }

    private struct Block {
        let range: NSRange
        let rect: NSRect
        let language: String?
    }

    private func blocks() -> [Block] {
        if let cachedBlocks { return cachedBlocks }
        guard let storage = textContentStorage, let manager = textLayoutManager, let textStorage else { return [] }

        let width = textContainer?.size.width ?? bounds.width
        var result: [Block] = []
        for key in [NSAttributedString.Key.markdownCodeBlock, .markdownTable] {
            textStorage.enumerateAttribute(key, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
                guard value != nil,
                      let start = storage.location(storage.documentRange.location, offsetBy: range.location),
                      let end = storage.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end)
                else { return }

                var union = NSRect.null
                manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                    union = union.union(frame)
                    return true
                }
                guard !union.isNull else { return }

                let language = value as? String
                let top = MarkdownAttributedString.blockPadding + (language?.isEmpty == false ? MarkdownAttributedString.codeLabelHeight : 0)
                let rect = NSRect(x: 0, y: union.minY - top, width: width, height: union.height + top + MarkdownAttributedString.blockPadding)
                result.append(Block(range: range, rect: rect, language: language))
            }
        }
        let sorted = result.sorted { $0.rect.minY < $1.rect.minY }
        cachedBlocks = sorted
        return sorted
    }

    private func copyFrame(of block: Block) -> NSRect {
        NSRect(x: block.rect.maxX - 30, y: block.rect.minY + 4, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSColor(theme.foreground).withAlphaComponent(0.06)
        let secondary = NSColor(theme.secondary)
        for (index, block) in blocks().enumerated() where block.rect.intersects(dirtyRect) {
            fill.setFill()
            NSBezierPath(roundedRect: block.rect, xRadius: 10, yRadius: 10).fill()
            guard let language = block.language else { continue }

            if !language.isEmpty {
                NSAttributedString(string: language, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: secondary])
                    .draw(at: NSPoint(x: MarkdownAttributedString.blockPadding, y: block.rect.minY + 8))
            }
            guard hoveredBlock == index || copiedBlock == index else { continue }

            let symbol = copiedBlock == index ? "checkmark" : "doc.on.doc"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Copy")?.withSymbolConfiguration(.init(paletteColors: [secondary]))
            image?.draw(in: NSRect(x: copyFrame(of: block).midX - 7, y: copyFrame(of: block).midY - 7, width: 14, height: 14))
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let hovered = blocks().firstIndex { $0.language != nil && $0.rect.contains(point) }
        guard hovered != hoveredBlock else { return }

        hoveredBlock = hovered
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredBlock = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let all = blocks()
        guard let index = all.firstIndex(where: { $0.language != nil && copyFrame(of: $0).contains(point) }) else { return super.mouseDown(with: event) }

        let code = (string as NSString).substring(with: all[index].range).trimmingCharacters(in: .newlines)
        copyToPasteboard(code)
        copiedBlock = index
        needsDisplay = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.copiedBlock = nil
            self?.needsDisplay = true
        }
    }
}
