import AppKit
import BerthCore
import SwiftUI

struct ReviewReference {
    let path: String
    let location: LanguageServerLocation
    let text: String
    let isBase: Bool
}

final class ReviewReferencesPeek: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate, NSSplitViewDelegate {
    private final class Group {
        let title: String
        let rows: [Row]

        init(title: String, rows: [Row]) {
            self.title = title
            self.rows = rows
        }
    }

    private final class Row {
        let reference: ReviewReference
        let line: String
        let match: NSRange
        let offset: Int

        init(reference: ReviewReference) {
            self.reference = reference
            let lines = reference.text.components(separatedBy: "\n")
            let start = reference.location.range.start
            let end = reference.location.range.end
            let line = lines.indices.contains(start.line) ? lines[start.line] : ""
            let text = line as NSString
            let column = min(start.character, text.length)
            let wordEnd = (column..<text.length).first { index in
                guard let scalar = UnicodeScalar(text.character(at: index)) else { return true }

                return !(scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar))
            } ?? text.length
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            self.line = String(line.dropFirst(indent.count))
            match = NSRange(location: max(column - indent.utf16.count, 0), length: end.line == start.line && end.character > column ? min(end.character, text.length) - column : wordEnd - column)
            offset = lines.prefix(start.line).reduce(0) { $0 + $1.utf16.count + 1 } + column
        }
    }

    static let height: CGFloat = 260
    static let stackedHeight: CGFloat = 360
    static let stackedBelowWidth: CGFloat = 560
    let list = ReviewReferencesList()
    private let header = NSTextField(labelWithString: "")
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(), target: nil, action: nil)
    private let preview = ReviewReferencesPreview(usingTextLayoutManager: true)
    private let previewScroll = NSScrollView()
    private let listScroll = NSScrollView()
    let split = ReviewSplitView()
    @AppStorage("reviewReferencesSplitRatio") private var listRatio = 0.38
    private let groups: [Group]
    private let style: ReviewStyle
    private let onOpen: (ReviewReference) -> Void
    private let onClose: () -> Void
    private var previewed: (path: String, isBase: Bool)?

    init(references: [ReviewReference], current: String, style: ReviewStyle, onOpen: @escaping (ReviewReference) -> Void, onClose: @escaping () -> Void) {
        let titles = references.map { $0.isBase ? "\($0.path) (old)" : $0.path }
        let ordered = Set(titles).sorted { ($0 == current ? 0 : 1, $0) < ($1 == current ? 0 : 1, $1) }
        groups = ordered.map { title in
            Group(title: title, rows: zip(titles, references).filter { $0.0 == title }.map(\.1).sorted { ($0.location.range.start.line, $0.location.range.start.character) < ($1.location.range.start.line, $1.location.range.start.character) }.map(Row.init))
        }
        self.style = style
        self.onOpen = onOpen
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        layer?.borderColor = style.commentBorder.cgColor
        layer?.backgroundColor = style.commentBackground.cgColor

        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        header.textColor = style.secondary
        header.lineBreakMode = .byTruncatingMiddle
        close.isBordered = false
        close.contentTintColor = style.secondary
        close.toolTip = "Close"
        close.target = self
        close.action = #selector(closePeek)

        preview.isEditable = false
        preview.isRichText = false
        preview.writingToolsBehavior = .none
        preview.font = style.font
        preview.textColor = style.foreground
        preview.backgroundColor = style.background
        preview.selectedTextAttributes = [.backgroundColor: style.selection]
        preview.textContainerInset = NSSize(width: 8, height: 6)
        preview.isHorizontallyResizable = true
        preview.isVerticallyResizable = true
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        preview.textContainer?.widthTracksTextView = false
        preview.textContainer?.containerSize = preview.maxSize
        preview.delegate = self
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.backgroundColor = style.background

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reference"))
        list.addTableColumn(column)
        list.outlineTableColumn = column
        list.headerView = nil
        list.style = .plain
        list.rowSizeStyle = .custom
        list.rowHeight = 20
        list.indentationPerLevel = 10
        list.backgroundColor = style.commentBackground
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(openSelected)
        list.onOpen = { [weak self] in self?.openSelected() }
        list.onClose = { [weak self] in self?.onClose() }
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false

        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.resetRatio = 1 - 0.38
        split.onDrag = { [weak self] ratio in
            guard let self else { return }

            listRatio = 1 - ratio
            split.resizeSubviews(withOldSize: split.frame.size)
        }
        split.addSubview(previewScroll)
        split.addSubview(listScroll)
        for view in [header, close, split] { addSubview(view) }
        list.reloadData()
        list.expandItem(nil, expandChildren: true)
        let start = groups.first?.rows.first
        if let start { list.selectRowIndexes(IndexSet(integer: list.row(forItem: start)), byExtendingSelection: false) }
        updateHeader()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool { true }

    var title: String { header.stringValue }
    var previewSelection: String { (preview.string as NSString).substring(with: preview.selectedRange()) }
    var previewTop: CGFloat { previewScroll.contentView.bounds.minY }
    var selectedReference: ReviewReference? { selectedRow?.reference }
    var outline: [String] {
        groups.map { group in "\(group.title) (\(group.rows.count)): " + group.rows.map { "\($0.reference.location.range.start.line + 1):\($0.reference.location.range.start.character + 1) \($0.line.debugDescription)" }.joined(separator: ", ") }
    }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 26
        header.frame = NSRect(x: 10, y: (headerHeight - 16) / 2, width: bounds.width - 44, height: 16)
        close.frame = NSRect(x: bounds.width - 26, y: (headerHeight - 16) / 2, width: 16, height: 16)
        split.frame = NSRect(x: 1, y: headerHeight, width: bounds.width - 2, height: bounds.height - headerHeight - 1)
        let isVertical = bounds.width >= Self.stackedBelowWidth
        if split.isVertical != isVertical {
            split.isVertical = isVertical
            split.resizeSubviews(withOldSize: split.frame.size)
        }
        scrollPreview()
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize _: NSSize) {
        let available = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        guard available > 0 else { return splitView.adjustSubviews() }

        let minimum = min(splitView.isVertical ? 100 : 60, (available / 2).rounded(.down))
        let position = min(max((1 - listRatio) * available, minimum), available - minimum).rounded()
        let edge: CGRectEdge = splitView.isVertical ? .minXEdge : .minYEdge
        let (preview, rest) = splitView.bounds.divided(atDistance: position, from: edge)
        previewScroll.frame = preview
        listScroll.frame = rest.divided(atDistance: splitView.dividerThickness, from: edge).remainder
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        let available = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        return max(proposedMinimumPosition, min(splitView.isVertical ? 100 : 60, (available / 2).rounded(.down)))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        let available = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        return min(proposedMaximumPosition, available - min(splitView.isVertical ? 100 : 60, (available / 2).rounded(.down)))
    }

    func splitView(_ splitView: NSSplitView, effectiveRect _: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt _: Int) -> NSRect {
        splitView.isVertical ? drawnRect.insetBy(dx: -3, dy: 0) : drawnRect.insetBy(dx: 0, dy: -3)
    }

    func splitViewDidResizeSubviews(_: Notification) {
        list.tableColumns.first?.width = listScroll.frame.width - 23
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with _: NSEvent) {}

    override func resetCursorRects() {
        let drawn = split.isVertical ? NSRect(x: previewScroll.frame.maxX, y: 0, width: split.dividerThickness, height: split.bounds.height) : NSRect(x: 0, y: previewScroll.frame.maxY, width: split.bounds.width, height: split.dividerThickness)
        let divider = convert(splitView(split, effectiveRect: drawn, forDrawnRect: drawn, ofDividerAt: 0), from: split)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: divider.minY), cursor: .arrow)
        addCursorRect(NSRect(x: 0, y: divider.minY, width: divider.minX, height: divider.height), cursor: .arrow)
        addCursorRect(NSRect(x: divider.maxX, y: divider.minY, width: bounds.width - divider.maxX, height: divider.height), cursor: .arrow)
        addCursorRect(NSRect(x: 0, y: divider.maxY, width: bounds.width, height: bounds.height - divider.maxY), cursor: .arrow)
    }

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? Group else { return item == nil ? groups.count : 0 }

        return group.rows.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? Group else { return groups[index] }

        return group.rows[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group
    }

    func outlineView(_: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
        ReviewReferencesRowView()
    }

    func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        if let group = item as? Group {
            let name = (group.title as NSString).lastPathComponent
            let folder = (group.title as NSString).deletingLastPathComponent
            let text = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), .foregroundColor: style.foreground])
            text.append(NSAttributedString(string: "  \(folder)  \(group.rows.count)", attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: style.secondary]))
            label.attributedStringValue = text
            label.toolTip = group.title
        } else if let row = item as? Row {
            let text = NSMutableAttributedString(string: row.line, attributes: [.font: style.font, .foregroundColor: style.foreground])
            if NSMaxRange(row.match) <= text.length { text.addAttribute(.backgroundColor, value: style.link.withAlphaComponent(0.3), range: row.match) }
            label.attributedStringValue = text
        }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(attributedString: label.attributedStringValue)
        text.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: text.length))
        label.attributedStringValue = text
        return label
    }

    func outlineViewSelectionDidChange(_: Notification) {
        updateHeader()
        guard let row = selectedRow else { return }

        let reference = row.reference
        if previewed?.path != reference.path || previewed?.isBase != reference.isBase {
            previewed = (reference.path, reference.isBase)
            let text = NSMutableAttributedString(string: reference.text, attributes: [.font: style.font, .foregroundColor: style.foreground])
            for span in ReviewHighlighter.spans(in: reference.text, path: reference.path) where NSMaxRange(span.range) <= text.length {
                text.addAttributes([.foregroundColor: style.color(forCapture: span.capture), .font: style.font(forCapture: span.capture)], range: span.range)
            }
            preview.textStorage?.setAttributedString(text)
        }

        preview.setSelectedRange(NSRange(location: min(row.offset, (reference.text as NSString).length), length: row.match.length))
        scrollPreview()
    }

    private func scrollPreview() {
        let range = preview.selectedRange()
        preview.scrollRangeToVisible(range)
        guard let manager = preview.textLayoutManager, let storage = preview.textContentStorage, let location = storage.location(storage.documentRange.location, offsetBy: range.location),
              let y = manager.textLayoutFragment(for: location)?.layoutFragmentFrame.minY
        else { return }

        previewScroll.contentView.scroll(to: NSPoint(x: 0, y: max(y + preview.textContainerInset.height - previewScroll.contentSize.height / 3, 0)))
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
    }

    func textView(_: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }

        onClose()
        return true
    }

    private var selectedRow: Row? {
        list.item(atRow: list.selectedRow) as? Row
    }

    private func updateHeader() {
        let count = groups.map(\.rows.count).reduce(0, +)
        header.stringValue = "\(selectedRow.map { "\($0.reference.path):\($0.reference.location.range.start.line + 1)  " } ?? "")References (\(count))"
    }

    @objc private func openSelected() {
        guard let row = selectedRow else { return }

        onOpen(row.reference)
    }

    @objc private func closePeek() {
        onClose()
    }
}

final class ReviewReferencesList: NSOutlineView {
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if [36, 76].contains(event.keyCode), flags.isEmpty {
            onOpen()
        } else if event.keyCode == 53, flags.isEmpty {
            onClose()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class ReviewReferencesRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

private final class ReviewReferencesPreview: NSTextView {
    override func viewDidEndLiveResize() {
        let origin = enclosingScrollView?.contentView.bounds.origin
        super.viewDidEndLiveResize()
        if let origin { scroll(origin) }
    }
}
