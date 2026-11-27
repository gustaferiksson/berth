import AppKit
import SwiftUI

struct ConversationTextView: NSViewRepresentable {
    enum Sizing {
        case fill, hug
    }

    let text: NSAttributedString
    var selectionID: String?
    var sizing = Sizing.fill

    @Environment(\.conversationFolder) private var folder
    @Environment(\.conversationExpansion) private var expansion
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.conversationSelection) private var selection

    func makeNSView(context _: Context) -> ConversationNSTextView {
        let view = ConversationNSTextView(usingTextLayoutManager: true)
        view.configure()
        return view
    }

    func updateNSView(_ view: ConversationNSTextView, context _: Context) {
        view.theme = theme
        view.openURL = { openURL($0) }
        view.toggleExpansion = { key in
            selection?.clear()
            expansion?.toggle(key)
        }
        view.selectionID = selectionID
        view.selection = selectionID == nil ? nil : selection
        view.show(text)
        view.selection?.register(view, folder: folder)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ConversationNSTextView, context _: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        let height = view.height(fitting: width)
        return CGSize(width: sizing == .hug ? min(width, view.usedWidth) : width, height: height)
    }
}

final class ConversationNSTextView: NSTextView, NSTextViewDelegate {
    var theme = GhosttyTheme(values: [:]) {
        didSet {
            guard theme != oldValue else { return }

            needsDisplay = true
        }
    }

    var openURL: (URL) -> Void = { _ in }
    var toggleExpansion: (String) -> Void = { _ in }
    var selectionID: String?
    weak var selection: ConversationSelection?

    private var source: NSAttributedString?
    private var hoveredBlock: Int?
    private var copiedBlock: Int?
    private static let fits = NSMapTable<NSAttributedString, NSMutableDictionary>.weakToStrongObjects()

    private var fitted: (width: CGFloat, height: CGFloat, used: CGFloat)?
    private var cachedBlocks: [Block]?
    private var highlight: NSRange?

    func configure() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isRichText = false
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        delegate = self
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    var usedWidth: CGFloat {
        fitted?.used ?? bounds.width
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        guard resigned else { return false }

        if let selection { selection.focusLeft(self) } else { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return true
    }

    override func writeSelection(to pasteboard: NSPasteboard, types _: [NSPasteboard.PasteboardType]) -> Bool {
        let range = selectedRange()
        let text = selection.flatMap { $0.hasSelection ? $0.copiedText() : nil } ?? textStorage.map { ConversationSelection.plainText($0, in: range) } ?? ""
        guard !text.isEmpty else { return false }

        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(text, forType: .string)
    }

    override func copy(_: Any?) {
        _ = writeSelection(to: .general, types: [.string])
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(copy(_:)), let selection, selection.hasSelection else { return super.validateUserInterfaceItem(item) }

        return true
    }

    override func selectAll(_ sender: Any?) {
        guard selection?.selectAll(from: self) == true else { return super.selectAll(sender) }
    }

    func showSelection(_ range: NSRange?) {
        let shown = range.flatMap { $0.length > 0 ? $0 : nil }
        guard shown != highlight else { return }

        highlight = shown
        needsDisplay = true
    }

    private func position(in line: NSTextLineFragment, at point: CGPoint) -> (offset: Int, hit: Int?) {
        let range = line.characterRange
        let text = line.attributedString.string as NSString
        let end = NSMaxRange(range) > range.location && text.character(at: NSMaxRange(range) - 1) == 0x0A ? NSMaxRange(range) - 1 : NSMaxRange(range)
        let hit = line.characterIndex(for: point)
        guard hit != NSNotFound else { return (point.x <= 0 ? range.location : end, nil) }
        guard hit < end else { return (end, nil) }

        let middle = (line.locationForCharacter(at: hit).x + line.locationForCharacter(at: hit + 1).x) / 2
        return (point.x >= middle ? hit + 1 : hit, hit)
    }

    private func hitTest(text point: NSPoint) -> (offset: Int, hit: Int?) {
        guard let manager = textLayoutManager, let storage = textContentStorage else { return (0, nil) }

        var result = ((string as NSString).length, Int?.none)
        manager.enumerateTextLayoutFragments(from: storage.documentRange.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard point.y < frame.maxY else { return true }

            let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            let lines = fragment.textLineFragments
            guard point.y >= frame.minY, let line = lines.first(where: { point.y - frame.minY < $0.typographicBounds.maxY }) ?? lines.last else {
                result = (start, nil)
                return false
            }

            let found = position(in: line, at: CGPoint(x: point.x - frame.minX - line.typographicBounds.minX, y: point.y - frame.minY - line.typographicBounds.minY))
            result = (start + found.offset, found.hit.map { start + $0 })
            return false
        }
        return result
    }

    func characterOffset(at point: NSPoint) -> Int {
        hitTest(text: point).offset
    }

    func show(_ text: NSAttributedString) {
        guard source !== text else { return }

        source = text
        guard textStorage?.isEqual(to: text) != true else { return }

        textStorage?.setAttributedString(text)
        highlight = nil
        hoveredBlock = nil
        copiedBlock = nil
        fitted = nil
        cachedBlocks = nil
        needsDisplay = true
    }

    func height(fitting width: CGFloat) -> CGFloat {
        if let fitted, fitted.width == width { return fitted.height }
        guard let textContainer, let manager = textLayoutManager else { return 0 }

        if let source, let known = Self.fits.object(forKey: source)?[width] as? [CGFloat] {
            textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            cachedBlocks = nil
            fitted = (width, known[0], known[1])
            return known[0]
        }

        textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: manager.documentRange)
        cachedBlocks = nil
        let blocks = blocks()
        let height = ceil(max(manager.usageBoundsForTextContainer.maxY, blocks.map(\.rect.maxY).max() ?? 0))
        var used = 0.0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            used = fragment.textLineFragments.reduce(used) { max($0, fragment.layoutFragmentFrame.minX + $1.typographicBounds.maxX) }
            return true
        }
        let fit: (width: CGFloat, height: CGFloat, used: CGFloat) = (width, height, blocks.contains { $0.language != nil } ? width : min(width, ceil(used)))
        fitted = fit
        if let source {
            let widths = Self.fits.object(forKey: source) ?? NSMutableDictionary()
            widths[width] = [fit.height, fit.used]
            Self.fits.setObject(widths, forKey: source)
        }
        return height
    }

    func textView(_: NSTextView, clickedOnLink link: Any, at index: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }

        switch url.scheme {
        case "berth-expand":
            if textStorage?.attribute(.conversationCopyText, at: index, effectiveRange: nil) != nil,
               let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value {
                toggleExpansion(key)
            }

        case PromptMentions.linkScheme:
            let path = url.path(percentEncoded: false)
            var isDirectory = ObjCBool(false)
            guard textStorage?.attribute(.attachment, at: index, effectiveRange: nil) != nil,
                  path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return true }

            let file = URL(filePath: path)
            if isDirectory.boolValue {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                ConversationImagePreview.shared.showFile(file)
            }

        default:
            openURL(url)
        }
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
        let tint = NSColor(theme.foreground).withAlphaComponent(0.06)
        drawInlineCode()
        for (index, block) in blocks().enumerated() where block.rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: block.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            guard let language = block.language else {
                tint.setFill()
                path.fill()
                continue
            }

            let code = theme.code
            code.background.setFill()
            path.fill()
            code.foreground.withAlphaComponent(0.12).setStroke()
            path.stroke()

            if !language.isEmpty {
                NSAttributedString(string: language, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: code.secondary])
                    .draw(at: NSPoint(x: MarkdownAttributedString.blockPadding, y: block.rect.minY + 8))
            }
            guard hoveredBlock == index || copiedBlock == index else { continue }

            let symbol = copiedBlock == index ? "checkmark" : "doc.on.doc"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Copy")?.withSymbolConfiguration(.init(paletteColors: [code.secondary]))
            image?.draw(in: NSRect(x: copyFrame(of: block).midX - 7, y: copyFrame(of: block).midY - 7, width: 14, height: 14))
        }
        drawHighlight()
        super.draw(dirtyRect)
    }

    private func drawInlineCode() {
        guard let storage = textContentStorage, let manager = textLayoutManager, let textStorage else { return }

        NSColor(theme.foreground).withAlphaComponent(0.08).setFill()
        textStorage.enumerateAttribute(.markdownInlineCode, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard value != nil,
                  let start = storage.location(storage.documentRange.location, offsetBy: range.location),
                  let end = storage.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return }

            let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont

            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { segment, frame, _, _ in
                var box = frame.insetBy(dx: -3, dy: 1)
                if let font, let location = segment?.location,
                   let fragment = manager.textLayoutFragment(for: location),
                   let line = fragment.textLineFragments.first(where: { $0.characterRange.contains(storage.offset(from: fragment.rangeInElement.location, to: location)) }) {
                    let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                    box = NSRect(x: frame.minX - 3, y: baseline - font.ascender - 1, width: frame.width + 6, height: font.ascender - font.descender + 2)
                }
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                return true
            }
        }
    }

    private func drawHighlight() {
        guard let highlight,
              let storage = textContentStorage,
              let manager = textLayoutManager,
              let start = storage.location(storage.documentRange.location, offsetBy: highlight.location),
              let end = storage.location(start, offsetBy: highlight.length),
              let range = NSTextRange(location: start, end: end)
        else { return }

        (window?.isKeyWindow == true ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        manager.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            frame.fill()
            return true
        }
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
        guard let textStorage, let index = all.firstIndex(where: { $0.language != nil && copyFrame(of: $0).contains(point) }) else { return select(with: event, at: point) }

        let code = ConversationSelection.plainText(textStorage, in: all[index].range).trimmingCharacters(in: .newlines)
        copyToPasteboard(code)
        copiedBlock = index
        needsDisplay = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.copiedBlock = nil
            self?.needsDisplay = true
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self { selection?.handOff(from: self, in: window) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func select(with event: NSEvent, at point: NSPoint) {
        let (offset, hit) = hitTest(text: point)
        let isLink = hit.map { textStorage?.attribute(.link, at: $0, effectiveRange: nil) != nil } ?? false
        guard let selection, event.clickCount == 1, !isLink, selection.begin(in: self, at: offset, extending: event.modifierFlags.contains(.shift)) else {
            super.mouseDown(with: event)
            guard let selection else { return }

            selection.adopt(self)
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            return
        }

        window?.makeFirstResponder(self)
    }
}
