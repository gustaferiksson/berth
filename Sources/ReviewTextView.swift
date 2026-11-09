import AppKit
import BerthCore
import SwiftUI

final class ReviewTextView: NSTextView, NSTextContentStorageDelegate {
    var theme = GhosttyTheme(values: [:]) {
        didSet { captureColors = [:] }
    }
    var tint = Color.clear
    var isAbsent = false
    var side: ReviewDiff.Side?
    var syntaxRuns: [ReviewHighlighter.Span] = []
    weak var gutter: ReviewGutter?
    private(set) var layoutManagerRequests = 0
    private var lineStarts = [0]
    private var rowHeight: CGFloat = 15
    private var paragraphStyle = NSParagraphStyle()
    private var captureColors: [String: NSColor] = [:]
    private var isStale = false

    override var layoutManager: NSLayoutManager? {
        layoutManagerRequests += 1
        return nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(newSize.width, enclosingScrollView?.contentSize.width ?? 0), height: newSize.height))
    }

    override func didChangeText() {
        isStale = true
        countLines()
        gutter?.needsDisplay = true
        super.didChangeText()
    }

    func refresh() {
        guard let storage = textContentStorage, let textStorage, let manager = textLayoutManager else { return }

        let font = theme.font
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        rowHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        style.tabStops = []
        style.defaultTabInterval = digitWidth * 4
        paragraphStyle = style
        countLines()

        let background = theme.background.map(NSColor.init) ?? .textBackgroundColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(theme.foreground), .paragraphStyle: style]
        backgroundColor = background
        enclosingScrollView?.backgroundColor = background
        insertionPointColor = NSColor(theme.foreground)
        typingAttributes = attributes

        let caret = window?.firstResponder === self ? selectedRange().location : nil
        let caretTop = caret.flatMap(fragmentTop).map { $0 - visibleRect.minY }
        storage.performEditingTransaction {
            textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
        }
        isStale = false
        manager.invalidateRenderingAttributes(for: manager.documentRange)
        manager.ensureLayout(for: manager.documentRange)
        if let caretTop, let top = caret.flatMap(fragmentTop) {
            scroll(NSPoint(x: visibleRect.minX, y: top - caretTop))
        }

        gutter?.thickness = (CGFloat(String(lineStarts.count).count) * digitWidth + 20).rounded(.up)
        gutter?.needsDisplay = true
        needsDisplay = true
    }

    func enumerateRows(in rect: NSRect, _ body: (_ line: Int, _ row: NSRect, _ fillers: [NSRect], _ startsLine: Bool) -> Void) {
        let origin = textContainerOrigin
        guard let storage = textContentStorage, let manager = textLayoutManager, let first = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(rect.minY - origin.y, 0))) else { return }

        manager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.minY < rect.maxY else { return false }

            let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            let line = lineStarts.partitioningIndex { $0 > offset } - 1
            let top = frame.minY + (fragment.textLineFragments.first?.typographicBounds.maxY ?? rowHeight) - rowHeight
            let bottom = frame.minY + (fragment.textLineFragments.last?.typographicBounds.maxY ?? rowHeight)
            let fillers = [NSRect(x: rect.minX, y: frame.minY, width: rect.width, height: top - frame.minY), NSRect(x: rect.minX, y: bottom, width: rect.width, height: frame.maxY - bottom)]
            body(line, NSRect(x: rect.minX, y: top, width: rect.width, height: rowHeight), fillers, lineStarts[line] == offset)
            return true
        }
    }

    func line(atY y: CGFloat) -> Int? {
        guard let storage = textContentStorage, let fragment = textLayoutManager?.textLayoutFragment(for: CGPoint(x: 0, y: y - textContainerOrigin.y)) else { return nil }

        let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
        return lineStarts.partitioningIndex { $0 > offset } - 1
    }

    func colorSyntax(in fragment: NSTextLayoutFragment) {
        guard !isStale, let storage = textContentStorage, let manager = textLayoutManager else { return }

        let range = fragment.rangeInElement
        let start = storage.offset(from: storage.documentRange.location, to: range.location)
        let end = storage.offset(from: storage.documentRange.location, to: range.endLocation)
        let add = { (key: NSAttributedString.Key, value: NSColor, span: NSRange) in
            let lower = max(span.location, start)
            let upper = min(NSMaxRange(span), end)
            guard lower < upper, let from = storage.location(range.location, offsetBy: lower - start), let to = storage.location(range.location, offsetBy: upper - start), let textRange = NSTextRange(location: from, end: to) else { return }
            manager.addRenderingAttribute(key, value: value, for: textRange)
        }

        manager.setRenderingAttributes([:], for: range)
        for run in syntaxRuns[syntaxRuns.partitioningIndex { NSMaxRange($0.range) > start }...].prefix(while: { $0.range.location < end }) {
            let color = captureColors[run.capture] ?? ReviewHighlighter.color(for: run.capture, theme: theme)
            captureColors[run.capture] = color
            add(.foregroundColor, color, run.range)
        }
        let words = side?.changedWordRangesInText ?? []
        for word in words[words.partitioningIndex { NSMaxRange($0) > start }...].prefix(while: { $0.location < end }) {
            add(.backgroundColor, NSColor(tint).withAlphaComponent(0.35), word)
        }
    }

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let side, let textStorage else { return nil }

        let line = lineStarts.partitioningIndex { $0 > range.location } - 1
        let endsLine = line + 1 == lineStarts.count || NSMaxRange(range) == lineStarts[line + 1]
        let before = range.location == 0 ? CGFloat(side.fillerBeforeFirstLine) * rowHeight : 0
        let after = endsLine ? CGFloat(side.fillerAfterLine[line, default: 0]) * rowHeight : 0
        guard before > 0 || after > 0 else { return nil }

        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(paragraphStyle)
        style.minimumLineHeight = rowHeight + before
        style.maximumLineHeight = rowHeight + before
        style.paragraphSpacing = after
        let text = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return NSTextParagraph(attributedString: text)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        let filler = NSColor(theme.foreground).withAlphaComponent(0.05)
        guard !isAbsent else {
            filler.setFill()
            rect.fill(using: .sourceOver)
            return
        }

        let changed = NSColor(tint).withAlphaComponent(0.2)
        enumerateRows(in: rect) { line, row, fillers, _ in
            if side?.changedLines.contains(line) == true {
                changed.setFill()
                row.fill(using: .sourceOver)
            }
            filler.setFill()
            fillers.forEach { $0.fill(using: .sourceOver) }
        }
    }

    private func countLines() {
        lineStarts = [0] + string.utf16.enumerated().compactMap { $0.element == 0x0A ? $0.offset + 1 : nil }
    }

    private func fragmentTop(atOffset offset: Int) -> CGFloat? {
        guard let storage = textContentStorage, let location = storage.location(storage.documentRange.location, offsetBy: offset) else { return nil }
        return textLayoutManager?.textLayoutFragment(for: location)?.layoutFragmentFrame.minY
    }
}

final class ReviewGutter: NSView {
    weak var textView: ReviewTextView?
    var selection: ClosedRange<Int>?
    var drawsSeparator = false
    var thickness: CGFloat = 40 {
        didSet { invalidateIntrinsicContentSize() }
    }
    var onSelect: (_ lines: ClosedRange<Int>, _ rect: NSRect) -> Void = { _, _ in }
    private var anchor: Int?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: thickness, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }

        textView.backgroundColor.setFill()
        bounds.fill()
        if drawsSeparator {
            NSColor(textView.theme.foreground).withAlphaComponent(0.1).setFill()
            NSRect(x: 0, y: 0, width: 1 / (window?.backingScaleFactor ?? 2), height: bounds.height).fill(using: .sourceOver)
        }

        let number = NSColor(textView.theme.secondary)
        let changed = NSColor(textView.tint)
        textView.enumerateRows(in: textView.visibleRect) { line, row, _, startsLine in
            guard startsLine else { return }

            let rect = convert(row, from: textView)
            if selection?.contains(line) == true {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill()
                NSRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height).fill(using: .sourceOver)
            }
            let label = NSAttributedString(string: "\(line + 1)", attributes: [.font: textView.theme.font, .foregroundColor: textView.side?.changedLines.contains(line) == true ? changed : number])
            label.draw(at: NSPoint(x: bounds.width - label.size().width - 8, y: rect.minY))
        }
    }

    override func mouseDown(with event: NSEvent) {
        anchor = line(at: event)
        selection = anchor.map { $0...$0 }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor, let line = line(at: event) else { return }
        selection = min(anchor, line)...max(anchor, line)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard anchor != nil, let selection else { return }
        anchor = nil
        onSelect(selection, NSRect(origin: convert(event.locationInWindow, from: nil), size: .zero).insetBy(dx: -1, dy: -1))
    }

    private func line(at event: NSEvent) -> Int? {
        guard let textView else { return nil }
        return textView.line(atY: textView.convert(event.locationInWindow, from: nil).y)
    }
}

extension RandomAccessCollection {
    func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if belongsInSecondPartition(self[index(startIndex, offsetBy: middle)]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}
