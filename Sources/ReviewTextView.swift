import AppKit
import BerthCore

// TextKit 2's viewport layout flushes fragments outside the viewport: they come back at estimated positions (rows off `top(ofRow:)`), and NSTextView's `textContainerOrigin` lays out the whole document again on the next pass.
final nonisolated class ReviewTextLayoutManager: NSTextLayoutManager {
    @objc(flushTextLayoutFragmentsFromLocation:direction:) func keepTextLayoutFragments(from _: any NSTextLocation, direction _: Int) {}
}

final class ReviewTextView: NSTextView, NSTextContentStorageDelegate {
    private typealias PointerTarget = (textView: ReviewTextView, range: NSRange, segments: [(rect: NSRect, baseline: CGFloat)])

    var style = ReviewStyle(scheme: .oneDark, fontFamily: "", fontSize: 0, lineHeightMultiple: 1.3, ghostty: GhosttyTheme(values: [:]))
    var kind = ReviewComment.Side.modified
    var isAbsent = false
    var side: ReviewDiff.Side?
    var syntaxRuns: [ReviewHighlighter.Span] = []
    var reserved: [Int: CGFloat] = [:] {
        didSet { reloadParagraphs(changedFrom: oldValue) }
    }

    var selectedLines: ClosedRange<Int>?
    weak var unifiedOriginal: ReviewTextView?
    var minimumWidth: CGFloat = 0
    var minimumHeight: CGFloat = 0
    var diagnostics: [LanguageServerDiagnostic] = [] {
        didSet { if diagnostics != oldValue { placeDiagnostics() } }
    }

    var onHover: ((Int) async -> String?)?
    var onDefinition: ((Int) -> Void)?
    var onReferences: ((Int) -> Void)?
    var focusesInWindow = false {
        didSet { if focusesInWindow, window != nil { focusInWindow() } }
    }

    weak var gutter: ReviewGutter?
    let history = UndoManager()
    var carets = CaretState()
    private(set) var layoutManagerRequests = 0
    private(set) var lineStarts = [0]
    private(set) var rowHeight: CGFloat = 15
    private var lastChange: (index: Int, y: CGFloat)?
    private var rowPadding: CGFloat = 0
    private var paragraphStyle = NSParagraphStyle()
    private var isStale = false
    private var coloredParagraphs = IndexSet()
    private var diagnosticSegments: [(rect: NSRect, baseline: CGFloat, diagnostic: LanguageServerDiagnostic)] = []
    private var taggedRanges: [NSRange: Set<LanguageServerDiagnostic.Tag>] = [:]
    private var link: PointerTarget?
    private var hoverTarget: PointerTarget?
    private var hoverDiagnostics: [LanguageServerDiagnostic] = []
    private var hoverTask: Task<Void, Never>?
    private var hoverCard: NSView?
    private var hoverClickMonitor: Any?
    private var flagsMonitor: Any?
    private(set) var occurrences: [NSRange] = [] {
        didSet { if occurrences != oldValue { needsDisplay = true } }
    }

    private var occurrenceSearch: Task<Void, Never>?
    private lazy var pointerTracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)

    override var layoutManager: NSLayoutManager? {
        layoutManagerRequests += 1
        return nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(newSize.width, enclosingScrollView?.contentSize.width ?? 0, minimumWidth), height: max(newSize.height, minimumHeight)))
    }

    // NSTextView scrolls back to the insertion point when a live resize ends, dropping the reader's horizontal scroll.
    override func viewDidEndLiveResize() {
        let origin = enclosingScrollView?.contentView.bounds.origin
        super.viewDidEndLiveResize()
        if let origin { scroll(origin) }
    }

    override func didChangeText() {
        isStale = true
        countLines()
        dismissHover()
        link = nil
        occurrenceSearch?.cancel()
        occurrences = []
        gutter?.needsDisplay = true
        super.didChangeText()
        placeDiagnostics()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !trackingAreas.contains(pointerTracking) { addTrackingArea(pointerTracking) }
        if focusesInWindow, window != nil { focusInWindow() }
    }

    private func focusInWindow() {
        focusesInWindow = false
        DispatchQueue.main.async { [weak self] in if let self { window?.makeFirstResponder(self) } }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pointerMoved(to: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard event.trackingArea === pointerTracking, onDefinition != nil, flagsMonitor == nil else { return }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let window else { return event }

            pointerMoved(to: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: event.modifierFlags)
            return event
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard event.trackingArea === pointerTracking else { return }

        flagsMonitor.map(NSEvent.removeMonitor)
        flagsMonitor = nil
        dismissHover()
        if link != nil {
            link = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        dismissHover()
        if caretMouseDown(event) { return }
        guard event.modifierFlags.contains(.command), onDefinition != nil, let target = pointerTarget(at: convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }

        link = nil
        needsDisplay = true
        target.textView.onDefinition?(target.range.location)
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 111, event.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift, onReferences != nil else { return super.keyDown(with: event) }

        findReferences(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard onReferences != nil, let target = pointerTarget(at: convert(event.locationInWindow, from: nil)), let onReferences = target.textView.onReferences else { return menu }

        let item = NSMenuItem(title: "Find References", action: #selector(findReferences), keyEquivalent: "\u{F70F}")
        item.keyEquivalentModifierMask = .shift
        item.target = self
        item.representedObject = { onReferences(target.range.location) }
        menu?.insertItem(item, at: 0)
        menu?.insertItem(.separator(), at: 1)
        return menu
    }

    @objc func findReferences(_ sender: Any?) {
        if let find = (sender as? NSMenuItem)?.representedObject as? () -> Void { return find() }

        let caret = selectedRange().location
        guard let onReferences, let identifier = identifierRange(at: caret) ?? identifierRange(at: caret - 1) else { return }

        onReferences(identifier.location)
    }

    // NSTextView maps Esc to word completion (complete:).
    override func cancelOperation(_: Any?) {
        dismissHover()
    }

    func offset(of position: LanguageServerPosition) -> Int {
        let length = (string as NSString).length
        guard lineStarts.indices.contains(position.line) else { return length }

        let end = position.line + 1 < lineStarts.count ? lineStarts[position.line + 1] - 1 : length
        return min(lineStarts[position.line] + max(position.character, 0), end, length)
    }

    func position(ofOffset offset: Int) -> LanguageServerPosition {
        let line = lineStarts.partitioningIndex { $0 > offset } - 1
        return LanguageServerPosition(line: line, character: offset - lineStarts[line])
    }

    func reveal(_ range: NSRange) {
        let line = lineStarts.partitioningIndex { $0 > range.location } - 1
        let row = side.map { $0.rows.indices.contains(line) ? $0.rows[line] : line } ?? line
        window?.makeFirstResponder(self)
        setSelectedRange(range.length > 0 ? range : identifierRange(at: range.location) ?? range)
        scrollVertically(to: top(ofRow: row) - (enclosingScrollView?.contentView.bounds.height ?? 0) / 3)
    }

    func dismissHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverTarget = nil
        hoverDiagnostics = []
        hoverClickMonitor.map(NSEvent.removeMonitor)
        hoverClickMonitor = nil
        if let hoverCard, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: hoverCard) { window?.makeFirstResponder(self) }
        hoverCard?.removeFromSuperview()
        hoverCard = nil
    }

    private func pointerMoved(to point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        let target = onHover == nil ? nil : pointerTarget(at: point)
        let newLink = modifiers.contains(.command) && onDefinition != nil ? target : nil
        if newLink != nil || link != nil { (newLink == nil ? NSCursor.iBeam : .pointingHand).set() }
        if newLink?.textView !== link?.textView || newLink?.range != link?.range {
            link = newLink
            needsDisplay = true
        }
        let problems = diagnosticSegments.filter { $0.rect.contains(point) }
        let unchanged = target?.textView === hoverTarget?.textView && target?.range == hoverTarget?.range && problems.map(\.diagnostic) == hoverDiagnostics
        if let hoverCard {
            if hoverCard.frame.contains(point) || unchanged {
                hoverTask?.cancel()
                hoverTask = nil
                return
            }
            if target == nil, problems.isEmpty {
                if hoverTask == nil {
                    hoverTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }

                        self?.dismissHover()
                    }
                }
                return
            }
        }
        guard !unchanged else { return }

        dismissHover()
        hoverTarget = target
        hoverDiagnostics = problems.map(\.diagnostic)
        let onHover = target?.textView.onHover
        let location = target?.range.location ?? 0
        let diagnostics = hoverDiagnostics
        guard onHover != nil || !diagnostics.isEmpty, let anchor = target?.segments.first?.rect ?? problems.first?.rect else { return }

        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            let markdown = await onHover?(location)
            guard !Task.isCancelled, markdown != nil || !diagnostics.isEmpty else { return }

            self?.showHover(markdown, diagnostics: diagnostics, below: anchor)
        }
    }

    private func pointerTarget(at point: NSPoint) -> PointerTarget? {
        if let identifier = identifier(at: point) { return (self, identifier, segments(of: identifier)) }
        guard let original = unifiedOriginal, let side, let originalSide = original.side, side.lineCount == lineStarts.count else { return nil }

        let row = (0..<side.rowCount).partitioningIndex { top(ofRow: $0) > point.y } - 1
        let line = originalSide.rows.partitioningIndex { $0 >= row }
        guard originalSide.rows.indices.contains(line), originalSide.rows[line] == row, originalSide.changedLines.contains(line), point.y < top(ofRow: row) + rowHeight,
              let found = original.identifier(onLine: line, atX: point.x - textContainerOrigin.x)
        else { return nil }

        let rect = NSRect(x: found.x.lowerBound + textContainerOrigin.x, y: top(ofRow: row), width: found.x.upperBound - found.x.lowerBound, height: rowHeight - rowPadding)
        return (original, found.range, [(rect, rect.maxY + style.font.descender)])
    }

    private func identifier(onLine line: Int, atX x: CGFloat) -> (range: NSRange, x: ClosedRange<CGFloat>)? {
        guard let storage = textContentStorage, let manager = textLayoutManager, lineStarts.indices.contains(line),
              let location = storage.location(storage.documentRange.location, offsetBy: lineStarts[line]), let lineRange = NSTextRange(location: location, end: storage.location(location, offsetBy: 1) ?? location)
        else { return nil }

        manager.ensureLayout(for: lineRange)
        guard let fragment = manager.textLayoutFragment(for: location), let first = fragment.textLineFragments.first else { return nil }

        let offset = fragment.layoutFragmentFrame.minX + first.typographicBounds.minX
        let index = lineStarts[line] + first.characterIndex(for: CGPoint(x: x - offset, y: first.typographicBounds.midY))
        for range in [identifierRange(at: index), identifierRange(at: index - 1)].compactMap(\.self) {
            let start = first.locationForCharacter(at: range.location - lineStarts[line]).x + offset
            let end = first.locationForCharacter(at: NSMaxRange(range) - lineStarts[line]).x + offset
            if (min(start, end)...max(start, end)).contains(x) { return (range, min(start, end)...max(start, end)) }
        }
        return nil
    }

    private func showHover(_ markdown: String?, diagnostics: [LanguageServerDiagnostic], below anchor: NSRect) {
        hoverTask = nil
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let problems = NSMutableAttributedString()
        for diagnostic in diagnostics {
            problems.append(NSAttributedString(string: (problems.length > 0 ? "\n" : "") + diagnostic.message, attributes: [.font: small, .foregroundColor: style.color(for: diagnostic.severity)]))
            if let source = diagnostic.source { problems.append(NSAttributedString(string: " (\(source))", attributes: [.font: small, .foregroundColor: style.secondary])) }
        }

        let info = NSMutableAttributedString()
        var isCode = false
        for line in (markdown ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                isCode.toggle()
                continue
            }
            info.append(NSAttributedString(string: (info.length > 0 ? "\n" : "") + line, attributes: [.font: isCode ? style.font : small, .foregroundColor: style.foreground]))
        }

        let labels = [problems, info].filter { $0.length > 0 }.map { text in
            let label = HoverCardText(usingTextLayoutManager: false)
            label.isEditable = false
            label.drawsBackground = false
            label.textContainerInset = .zero
            label.textContainer?.lineFragmentPadding = 0
            label.textContainer?.widthTracksTextView = false
            label.textContainer?.containerSize = NSSize(width: min(520, visibleRect.width - 40), height: .greatestFiniteMagnitude)
            label.writingToolsBehavior = .none
            label.setAccessibilityRole(.staticText)
            label.onCancel = { [weak self] in self?.dismissHover() }
            label.textStorage?.setAttributedString(text)
            let container = label.textContainer ?? NSTextContainer()
            label.layoutManager?.ensureLayout(for: container)
            let used = label.layoutManager?.usedRect(for: container) ?? .zero
            label.frame.size = NSSize(width: used.width.rounded(.up), height: used.height.rounded(.up))
            label.textContainer?.containerSize.width = label.frame.width
            return label
        }
        let width = (labels.map(\.frame.width).max() ?? 0) + 20
        let card = NSView(frame: NSRect(x: 0, y: 0, width: width, height: labels.map { $0.frame.height + 16 }.reduce(0, +)))
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Hover information")
        card.wantsLayer = true
        card.layer?.backgroundColor = (style.background.blended(withFraction: 0.08, of: style.foreground) ?? style.background).cgColor
        card.layer?.borderColor = style.commentBorder.cgColor
        card.layer?.borderWidth = 1
        card.layer?.cornerRadius = 6
        var top = card.frame.height
        for label in labels {
            if top < card.frame.height {
                let separator = NSView(frame: NSRect(x: 0, y: top, width: width, height: 1))
                separator.wantsLayer = true
                separator.layer?.backgroundColor = style.commentBorder.cgColor
                card.addSubview(separator)
            }
            label.frame.origin = NSPoint(x: 10, y: top - 8 - label.frame.height)
            card.addSubview(label)
            top -= label.frame.height + 16
        }
        let below = anchor.maxY + 4
        card.frame.origin = NSPoint(x: max(min(anchor.minX, visibleRect.maxX - card.frame.width - 8), visibleRect.minX), y: below + card.frame.height > visibleRect.maxY ? anchor.minY - card.frame.height - 4 : below)
        addSubview(card)
        hoverCard = card
        hoverClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak card] event in
            guard let self, let card, event.window === window, !card.frame.contains(convert(event.locationInWindow, from: nil)) else { return event }

            dismissHover()
            return event
        }
    }

    private func identifier(at point: NSPoint) -> NSRange? {
        let origin = textContainerOrigin
        guard let storage = textContentStorage, let fragment = textLayoutManager?.textLayoutFragment(for: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) else { return nil }

        let local = CGPoint(x: point.x - origin.x - fragment.layoutFragmentFrame.minX, y: point.y - origin.y - fragment.layoutFragmentFrame.minY)
        guard let line = fragment.textLineFragments.first(where: { ($0.typographicBounds.minY..<$0.typographicBounds.maxY).contains(local.y) }) else { return nil }

        let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
        let index = start + line.characterIndex(for: CGPoint(x: local.x - line.typographicBounds.minX, y: local.y - line.typographicBounds.minY))
        return [identifierRange(at: index), identifierRange(at: index - 1)].compactMap(\.self).first { range in segments(of: range).contains { $0.rect.contains(point) } }
    }

    private func identifierRange(at offset: Int) -> NSRange? {
        let text = string as NSString
        let isIdentifier = { (index: Int) in
            guard index >= 0, index < text.length, let scalar = UnicodeScalar(text.character(at: index)) else { return false }

            return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
        }
        guard isIdentifier(offset) else { return nil }

        var start = offset
        var end = offset + 1
        while isIdentifier(start - 1) { start -= 1 }
        while isIdentifier(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    func segments(of range: NSRange) -> [(rect: NSRect, baseline: CGFloat)] {
        guard let storage = textContentStorage, let manager = textLayoutManager, let start = storage.location(storage.documentRange.location, offsetBy: range.location), let end = storage.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end) else { return [] }

        let origin = textContainerOrigin
        let glyphHeight = rowHeight - rowPadding
        var segments: [(rect: NSRect, baseline: CGFloat)] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, baseline, _ in
            segments.append((NSRect(x: frame.minX + origin.x, y: frame.maxY + origin.y - glyphHeight, width: frame.width, height: glyphHeight), frame.minY + origin.y + baseline))
            return true
        }
        return segments
    }

    private func placeDiagnostics() {
        let length = (string as NSString).length
        let ranges = diagnostics.map { diagnostic in
            let start = offset(of: diagnostic.range.start)
            let end = offset(of: diagnostic.range.end)
            return (diagnostic: diagnostic, range: end > start ? NSRange(location: start, length: end - start) : identifierRange(at: start) ?? identifierRange(at: start - 1) ?? NSRange(location: start, length: start < length ? 1 : 0))
        }
        diagnosticSegments = ranges.flatMap { item in segments(of: item.range).map { (rect: $0.rect, baseline: $0.baseline, diagnostic: item.diagnostic) } }

        let tagged = Dictionary(ranges.filter { !$0.diagnostic.tags.isEmpty }.map { ($0.range, $0.diagnostic.tags) }, uniquingKeysWith: { $0.union($1) })
        let changed = Set(tagged.keys).union(taggedRanges.keys).filter { tagged[$0] != taggedRanges[$0] }
        taggedRanges = tagged
        if let storage = textContentStorage, let manager = textLayoutManager {
            for span in changed {
                guard let location = storage.location(storage.documentRange.location, offsetBy: span.location) else { continue }

                manager.enumerateTextLayoutFragments(from: location) { fragment in
                    let start = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
                    guard start <= span.location || start < NSMaxRange(span) else { return false }

                    coloredParagraphs.remove(start)
                    colorSyntax(in: fragment)
                    return true
                }
            }
        }
        needsDisplay = true
        gutter?.needsDisplay = true
    }

    func highlightOccurrences(then redraw: @escaping () -> Void) {
        occurrenceSearch?.cancel()
        let selection = selectedRange()
        let needle = selectedRanges.count == 1 && selection.length > 0 ? textStorage?.mutableString.substring(with: selection) ?? "" : ""
        guard !needle.trimmingCharacters(in: .whitespaces).isEmpty, needle.rangeOfCharacter(from: .newlines) == nil else {
            occurrences = []
            return redraw()
        }

        let wholeWord = identifierRange(at: selection.location) == selection
        occurrenceSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let text = self?.string, !Task.isCancelled else { return }

            let found = await Task.detached {
                let text = text as NSString
                let identifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
                var ranges: [NSRange] = []
                var match = text.range(of: needle, options: .literal)
                while match.location != NSNotFound, ranges.count < 2000 {
                    let end = NSMaxRange(match)
                    let isWord = text.rangeOfCharacter(from: identifier, options: [.anchored, .backwards], range: NSRange(location: 0, length: match.location)).location == NSNotFound && text.rangeOfCharacter(from: identifier, options: .anchored, range: NSRange(location: end, length: text.length - end)).location == NSNotFound
                    if !wholeWord || isWord { ranges.append(match) }
                    match = text.range(of: needle, options: .literal, range: NSRange(location: end, length: text.length - end))
                }
                return ranges
            }.value
            guard !Task.isCancelled else { return }

            self?.occurrences = found.count > 1 ? found : []
            redraw()
        }
    }

    var occurrenceRows: IndexSet {
        IndexSet(occurrences.map { occurrence in
            let line = lineStarts.partitioningIndex { $0 > occurrence.location } - 1
            return side.map { $0.rows.indices.contains(line) ? $0.rows[line] : line } ?? line
        })
    }

    private func drawOccurrences(in rect: NSRect) {
        guard !occurrences.isEmpty else { return }

        let start = line(atY: rect.minY).map { lineStarts[$0] } ?? 0
        let end = line(atY: rect.maxY).flatMap { $0 + 1 < lineStarts.count ? lineStarts[$0 + 1] : nil } ?? textStorage?.length ?? 0
        let selection = selectedRange()
        style.foreground.withAlphaComponent(0.12).setFill()
        for occurrence in occurrences[occurrences.partitioningIndex { NSMaxRange($0) > start }...].prefix(while: { $0.location < end }) where occurrence != selection && !carets.ranges.contains(occurrence) {
            for segment in segments(of: occurrence) where segment.rect.intersects(rect) {
                NSBezierPath(roundedRect: segment.rect, xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    func refresh() {
        guard let storage = textContentStorage, let textStorage, let manager = textLayoutManager else { return }

        let font = style.font
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        rowHeight = style.lineHeight
        rowPadding = ((rowHeight - (font.ascender - font.descender + font.leading)) / 2).rounded()
        paragraph.minimumLineHeight = rowHeight - rowPadding
        paragraph.maximumLineHeight = rowHeight - rowPadding
        paragraph.paragraphSpacing = rowPadding
        paragraph.tabStops = []
        paragraph.defaultTabInterval = digitWidth * 4
        paragraphStyle = paragraph
        countLines()

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.foreground, .paragraphStyle: paragraph]
        backgroundColor = style.background
        enclosingScrollView?.backgroundColor = style.background
        insertionPointColor = style.foreground
        selectedTextAttributes = [.backgroundColor: style.selection]
        typingAttributes = attributes

        let caret = window?.firstResponder === self ? selectedRange().location : nil
        let caretTop = caret.flatMap(fragmentTop).map { $0 - visibleRect.minY }
        storage.performEditingTransaction {
            textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
            for run in syntaxRuns where NSMaxRange(run.range) <= textStorage.length && style.font(forCapture: run.capture) != font {
                textStorage.addAttribute(.font, value: style.font(forCapture: run.capture), range: run.range)
            }
        }
        isStale = false
        coloredParagraphs = IndexSet()
        manager.invalidateRenderingAttributes(for: manager.documentRange)
        manager.ensureLayout(for: manager.documentRange)
        setFrameSize(NSSize(width: frame.width, height: manager.usageBoundsForTextContainer.height + 2 * textContainerInset.height))
        if let caretTop, let top = caret.flatMap(fragmentTop) {
            scroll(NSPoint(x: visibleRect.minX, y: top - caretTop))
        }

        gutter?.thickness = (CGFloat(String(max(lineStarts.count, unifiedOriginal?.lineStarts.count ?? 0)).count) * digitWidth + 20).rounded(.up)
        placeDiagnostics()
    }

    func enumerateRows(in rect: NSRect, _ body: (_ line: Int, _ row: NSRect, _ fillers: [NSRect], _ startsLine: Bool) -> Void) {
        let origin = textContainerOrigin
        guard let storage = textContentStorage, let manager = textLayoutManager, let first = manager.textLayoutFragment(for: CGPoint(x: 0, y: max(rect.minY - origin.y, 0))) else { return }

        manager.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.minY < rect.maxY else { return false }

            let offset = storage.offset(from: storage.documentRange.location, to: fragment.rangeInElement.location)
            let line = lineStarts.partitioningIndex { $0 > offset } - 1
            let top = frame.minY + (fragment.textLineFragments.first?.typographicBounds.maxY ?? rowHeight) - rowHeight + rowPadding
            let bottom = frame.minY + (fragment.textLineFragments.last?.typographicBounds.maxY ?? rowHeight) + rowPadding
            let fillers = [NSRect(x: rect.minX, y: frame.minY, width: rect.width, height: top - frame.minY), NSRect(x: rect.minX, y: bottom, width: rect.width, height: frame.maxY - bottom)]
            body(line, NSRect(x: rect.minX, y: top, width: rect.width, height: rowHeight), fillers, lineStarts[line] == offset)
            return true
        }
    }

    var changedRows: IndexSet {
        guard let side else { return IndexSet() }

        return IndexSet(side.changedLines.compactMap { side.rows.indices.contains($0) ? side.rows[$0] : nil })
    }

    func top(ofRow row: Int) -> CGFloat {
        textContainerOrigin.y + CGFloat(row) * rowHeight + reserved.filter { $0.key < row }.values.reduce(0, +)
    }

    func goToChange(by direction: Int) {
        guard let side, let clip = enclosingScrollView?.contentView else { return }

        let covered = Set(side.rows)
        let changed = changedRows
        let isChange = { (row: Int) in !covered.contains(row) || changed.contains(row) }
        let starts = (0..<side.rowCount).filter { isChange($0) && ($0 == 0 || !isChange($0 - 1)) }
        guard !starts.isEmpty else { return }

        let tops = starts.map(top(ofRow:))
        let anchor = clip.bounds.minY + clip.bounds.height / 3
        let next: Int? = if let lastChange, abs(clip.bounds.minY - lastChange.y) < 0.5 {
            starts.indices.contains(lastChange.index + direction) ? lastChange.index + direction : nil
        } else if direction > 0 {
            tops.firstIndex { $0 > anchor + 1 }
        } else {
            tops.lastIndex { $0 < anchor - 1 }
        }
        if next == nil { NSSound.beep() }

        let index = next ?? (direction > 0 ? 0 : starts.count - 1)
        scrollVertically(to: tops[index] - clip.bounds.height / 3)
        lastChange = (index, clip.bounds.minY)
    }

    func scrollVertically(to y: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }

        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(y, 0), max(frame.height - clip.bounds.height, 0))))
        scrollView.reflectScrolledClipView(clip)
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
        guard !coloredParagraphs.contains(start) else { return }

        coloredParagraphs.insert(start)
        let add = { (key: NSAttributedString.Key, value: NSColor, span: NSRange) in
            let lower = max(span.location, start)
            let upper = min(NSMaxRange(span), end)
            guard lower < upper, let from = storage.location(range.location, offsetBy: lower - start), let to = storage.location(range.location, offsetBy: upper - start), let textRange = NSTextRange(location: from, end: to) else { return }

            manager.addRenderingAttribute(key, value: value, for: textRange)
        }

        manager.setRenderingAttributes([:], for: range)
        let faded = taggedRanges.filter { $0.value.contains(.unnecessary) && $0.key.location < end && NSMaxRange($0.key) > start }.keys
        for span in faded { add(.foregroundColor, style.foreground.withAlphaComponent(0.6), span) }
        for run in syntaxRuns[syntaxRuns.partitioningIndex { NSMaxRange($0.range) > start }...].prefix(while: { $0.range.location < end }) {
            let color = style.color(forCapture: run.capture)
            add(.foregroundColor, color, run.range)
            for span in faded { run.range.intersection(span).map { add(.foregroundColor, color.withAlphaComponent(0.6), $0) } }
        }
        let words = side?.changedWordRangesInText ?? []
        for word in words[words.partitioningIndex { NSMaxRange($0) > start }...].prefix(while: { $0.location < end }) {
            add(.backgroundColor, kind == .original ? style.removedWord : style.addedWord, word)
        }
    }

    func textContentStorage(_: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let side, let textStorage else { return nil }

        let line = lineStarts.partitioningIndex { $0 > range.location } - 1
        guard side.rows.indices.contains(line) else { return nil }

        let endsLine = line + 1 == lineStarts.count || NSMaxRange(range) == lineStarts[line + 1]
        let row = side.rows[line]
        let next = line + 1 < side.rows.count ? side.rows[line + 1] : side.rowCount
        let space = { (rows: Range<Int>) in CGFloat(rows.count) * self.rowHeight + self.reserved.filter { rows.contains($0.key) }.values.reduce(0, +) }
        let before = range.location == 0 ? space(0..<row) : 0
        let after = endsLine ? space(row..<next) - rowHeight : 0
        guard before > 0 || after > 0 else { return nil }

        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(paragraphStyle)
        style.minimumLineHeight = rowHeight - rowPadding + before
        style.maximumLineHeight = rowHeight - rowPadding + before
        style.paragraphSpacing = after + rowPadding
        let text = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return NSTextParagraph(attributedString: text)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        let changed = kind == .original ? style.removedLine : style.addedLine
        if isAbsent, unifiedOriginal == nil {
            style.filler.setFill()
            rect.fill(using: .sourceOver)
        } else {
            enumerateRows(in: rect) { line, row, fillers, _ in
                if side?.changedLines.contains(line) == true {
                    changed.setFill()
                    row.fill(using: .sourceOver)
                }
                if selectedLines?.contains(line) == true {
                    style.selection.setFill()
                    row.fill(using: .sourceOver)
                }
                style.filler.setFill()
                fillers.forEach { $0.fill(using: .sourceOver) }
            }
        }

        if let original = unifiedOriginal, let side = original.side, self.side?.lineCount == lineStarts.count {
            let text = original.string as NSString
            for line in side.rows.partitioningIndex(where: { top(ofRow: $0 + 1) > rect.minY })..<min(side.rows.count, original.lineStarts.count) {
                let row = NSRect(x: rect.minX, y: top(ofRow: side.rows[line]), width: rect.width, height: rowHeight)
                guard row.minY < rect.maxY else { break }

                if side.changedLines.contains(line) {
                    let start = original.lineStarts[line]
                    let end = line + 1 < original.lineStarts.count ? original.lineStarts[line + 1] - 1 : text.length
                    let content = NSMutableAttributedString(string: text.substring(with: NSRange(location: start, length: end - start)), attributes: [.font: style.font, .foregroundColor: style.foreground, .paragraphStyle: paragraphStyle])
                    for run in original.syntaxRuns[original.syntaxRuns.partitioningIndex { NSMaxRange($0.range) > start }...].prefix(while: { $0.range.location < end }) {
                        let lower = max(run.range.location, start)
                        content.addAttributes([.foregroundColor: style.color(forCapture: run.capture), .font: style.font(forCapture: run.capture)], range: NSRange(location: lower - start, length: min(NSMaxRange(run.range), end) - lower))
                    }
                    for word in side.changedWordRangesInText[side.changedWordRangesInText.partitioningIndex { NSMaxRange($0) > start }...].prefix(while: { $0.location < end }) {
                        let lower = max(word.location, start)
                        content.addAttribute(.backgroundColor, value: style.removedWord, range: NSRange(location: lower - start, length: min(NSMaxRange(word), end) - lower))
                    }
                    backgroundColor.setFill()
                    row.fill()
                    style.removedLine.setFill()
                    row.fill(using: .sourceOver)
                    content.draw(with: NSRect(x: textContainerOrigin.x, y: row.minY, width: .greatestFiniteMagnitude, height: rowHeight), options: [.usesLineFragmentOrigin])
                }
                if original.selectedLines?.contains(line) == true {
                    style.selection.setFill()
                    row.fill(using: .sourceOver)
                }
            }
        }

        backgroundColor.setFill()
        for (row, height) in reserved {
            NSRect(x: rect.minX, y: top(ofRow: row + 1) - height, width: rect.width, height: height).fill()
        }
        drawOccurrences(in: rect)

        for segment in diagnosticSegments where segment.rect.intersects(rect) {
            if segment.diagnostic.tags.contains(.deprecated) {
                style.foreground.setFill()
                NSRect(x: segment.rect.minX, y: (segment.baseline - style.font.xHeight / 2).rounded(), width: segment.rect.width, height: 1).fill()
            }
            guard segment.diagnostic.tags.isEmpty || [.error, .warning].contains(segment.diagnostic.severity) else { continue }

            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: segment.rect.minX, y: segment.baseline + 3))
            for (step, x) in stride(from: segment.rect.minX + 2, through: segment.rect.maxX, by: 2).enumerated() {
                wave.line(to: NSPoint(x: x, y: segment.baseline + (step.isMultiple(of: 2) ? 1.5 : 3)))
            }
            style.color(for: segment.diagnostic.severity).setStroke()
            wave.stroke()
        }
        if let link {
            style.link.setFill()
            for segment in link.textView === self ? segments(of: link.range) : link.segments { NSRect(x: segment.rect.minX, y: segment.baseline + 2, width: segment.rect.width, height: 1).fill() }
        }
        drawCarets(in: rect)
    }

    private func reloadParagraphs(changedFrom old: [Int: CGFloat]) {
        guard let side, let storage = textContentStorage, let textStorage, let manager = textLayoutManager else { return }

        let rows = Set(old.keys).union(reserved.keys).filter { old[$0] != reserved[$0] }
        let lines = Set(rows.map { row in max(side.rows.partitioningIndex { $0 > row } - 1, 0) }).filter { $0 < lineStarts.count }
        storage.performEditingTransaction {
            for line in lines {
                let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : textStorage.length
                coloredParagraphs.remove(lineStarts[line])
                textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: lineStarts[line], length: end - lineStarts[line]))
            }
        }
        manager.ensureLayout(for: manager.documentRange)
        setFrameSize(NSSize(width: frame.width, height: manager.usageBoundsForTextContainer.height + 2 * textContainerInset.height))
        layoutSubtreeIfNeeded()
        needsDisplay = true
        gutter?.needsDisplay = true
        placeDiagnostics()
    }

    private func countLines() {
        lineStarts = [0] + string.utf16.enumerated().compactMap { $0.element == 0x0A ? $0.offset + 1 : nil }
    }

    private func fragmentTop(atOffset offset: Int) -> CGFloat? {
        guard let storage = textContentStorage, let location = storage.location(storage.documentRange.location, offsetBy: offset) else { return nil }

        return textLayoutManager?.textLayoutFragment(for: location)?.layoutFragmentFrame.minY
    }
}

final class ReviewGutter: NSView, NSViewToolTipOwner {
    weak var textView: ReviewTextView?
    var thickness: CGFloat = 40 {
        didSet { invalidateIntrinsicContentSize() }
    }

    var onSelect: (ReviewTextView, ClosedRange<Int>) -> Void = { _, _ in }
    private var anchor: Int?
    private var target: ReviewTextView?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: thickness, height: NSView.noIntrinsicMetric)
    }

    override func draw(_: NSRect) {
        guard let textView else { return }

        textView.backgroundColor.setFill()
        bounds.fill()

        let style = textView.style
        let changed = (textView.kind == .original ? style.removedWord : style.addedWord).withAlphaComponent(1)
        let caret = textView.window?.firstResponder === textView ? textView.lineStarts.partitioningIndex { $0 > textView.selectedRange().location } - 1 : nil
        removeAllToolTips()
        textView.enumerateRows(in: textView.visibleRect) { line, row, _, startsLine in
            guard startsLine else { return }

            let rect = convert(row, from: textView)
            let isSelected = textView.selectedLines?.contains(line) == true
            if isSelected {
                style.selection.setFill()
                NSRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height).fill(using: .sourceOver)
            }
            if let worst = textView.diagnostics.filter({ $0.range.start.line == line && ($0.tags.isEmpty || [.error, .warning].contains($0.severity)) }).min(by: { ($0.severity?.rawValue ?? 4) < ($1.severity?.rawValue ?? 4) }) {
                let mark = NSRect(x: 4, y: rect.midY - 3, width: 6, height: 6)
                style.color(for: worst.severity).setFill()
                NSBezierPath(ovalIn: mark).fill()
                addToolTip(mark.insetBy(dx: -3, dy: -3), owner: self, userData: nil)
            }
            let color = textView.side?.changedLines.contains(line) == true ? changed : isSelected || line == caret ? style.currentLineNumber : style.gutterForeground
            let label = NSAttributedString(string: "\(line + 1)", attributes: [.font: style.font, .foregroundColor: color])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: rect.minY + (rect.height - size.height) / 2))
        }

        guard let original = textView.unifiedOriginal, let side = original.side, textView.side?.lineCount == textView.lineStarts.count else { return }

        let removed = style.removedWord.withAlphaComponent(1)
        for line in side.rows.partitioningIndex(where: { textView.top(ofRow: $0 + 1) > textView.visibleRect.minY })..<side.rows.count {
            let rect = convert(NSRect(x: 0, y: textView.top(ofRow: side.rows[line]), width: 1, height: textView.rowHeight), from: textView)
            guard rect.minY < bounds.maxY else { break }

            if original.selectedLines?.contains(line) == true {
                style.selection.setFill()
                NSRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height).fill(using: .sourceOver)
            }
            guard side.changedLines.contains(line) else { continue }

            let label = NSAttributedString(string: "\(line + 1)", attributes: [.font: style.font, .foregroundColor: removed])
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: rect.minY + (rect.height - size.height) / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView else { return }

        let y = textView.convert(event.locationInWindow, from: nil).y
        let row = (0..<(textView.side?.rowCount ?? 0)).partitioningIndex { textView.top(ofRow: $0) > y } - 1
        let rows = textView.side?.rows ?? []
        let index = rows.partitioningIndex { $0 >= row }
        textView.selectedLines = nil
        textView.unifiedOriginal?.selectedLines = nil
        target = textView.unifiedOriginal.flatMap { index < rows.count && rows[index] == row ? nil : $0 } ?? textView
        anchor = line(at: event)
        select(anchor.map { $0...$0 })
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor, let line = line(at: event) else { return }

        select(min(anchor, line)...max(anchor, line))
    }

    override func mouseUp(with _: NSEvent) {
        guard anchor != nil, let target, let selection = target.selectedLines else { return }

        anchor = nil
        onSelect(target, selection)
    }

    override func scrollWheel(with event: NSEvent) {
        textView?.enclosingScrollView?.scrollWheel(with: event)
    }

    func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?) -> String {
        guard let textView, let line = textView.line(atY: textView.convert(point, from: self).y) else { return "" }

        return textView.diagnostics.filter { $0.range.start.line == line }.map { $0.message + ($0.source.map { " (\($0))" } ?? "") }.joined(separator: "\n")
    }

    private func select(_ lines: ClosedRange<Int>?) {
        target?.selectedLines = lines
        textView?.needsDisplay = true
        needsDisplay = true
    }

    private func line(at event: NSEvent) -> Int? {
        guard let textView, let rows = target?.side?.rows else { return nil }

        let y = textView.convert(event.locationInWindow, from: nil).y
        let row = (0..<(textView.side?.rowCount ?? 0)).partitioningIndex { textView.top(ofRow: $0) > y } - 1
        return max(rows.partitioningIndex { $0 > row } - 1, 0)
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

private final class HoverCardText: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_: Any?) {
        onCancel?()
    }
}
