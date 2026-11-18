import AppKit
import BerthCore

struct ReviewReference {
    let path: String
    let location: LanguageServerLocation
    let text: String
    let isBase: Bool
}

final class ReviewReferencesPeek: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate {
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

        init(reference: ReviewReference) {
            self.reference = reference
            let start = reference.location.range.start
            let line = reference.text.components(separatedBy: "\n").dropFirst(start.line).first ?? ""
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            self.line = String(line.dropFirst(indent.count))
            let end = reference.location.range.end.line == start.line ? reference.location.range.end.character : line.utf16.count
            match = NSRange(location: max(start.character - indent.utf16.count, 0), length: max(min(end, line.utf16.count) - start.character, 0))
        }
    }

    static let height: CGFloat = 260
    let list = ReviewReferencesList()
    private let header = NSTextField(labelWithString: "")
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(), target: nil, action: nil)
    private let preview = NSTextView(usingTextLayoutManager: true)
    private let previewScroll = NSScrollView()
    private let listScroll = NSScrollView()
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

        for view in [header, close, previewScroll, listScroll] { addSubview(view) }
        list.reloadData()
        list.expandItem(nil, expandChildren: true)
        let start = groups.first?.rows.first
        if let start { list.selectRowIndexes(IndexSet(integer: list.row(forItem: start)), byExtendingSelection: false) }
        updateHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
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
        let listWidth = max(bounds.width * 0.38, min(bounds.width / 2, 220)).rounded()
        header.frame = NSRect(x: 10, y: (headerHeight - 16) / 2, width: bounds.width - 44, height: 16)
        close.frame = NSRect(x: bounds.width - 26, y: (headerHeight - 16) / 2, width: 16, height: 16)
        previewScroll.frame = NSRect(x: 1, y: headerHeight, width: bounds.width - listWidth - 1, height: bounds.height - headerHeight - 1)
        listScroll.frame = NSRect(x: bounds.width - listWidth, y: headerHeight, width: listWidth - 1, height: bounds.height - headerHeight - 1)
        list.tableColumns.first?.width = listWidth - 24
    }

    override func mouseDown(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let group = item as? Group else { return item == nil ? groups.count : 0 }
        return group.rows.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? Group else { return groups[index] }
        return group.rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
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

    func outlineViewSelectionDidChange(_ notification: Notification) {
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

        let lines = reference.text.components(separatedBy: "\n")
        let lineStarts = lines.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.utf16.count + 1) }
        let start = reference.location.range.start
        let end = reference.location.range.end
        let location = lineStarts.indices.contains(start.line) ? lineStarts[start.line] + start.character : 0
        let range = NSRange(location: min(location, (reference.text as NSString).length), length: lineStarts.indices.contains(end.line) ? max(lineStarts[end.line] + end.character - location, 0) : 0)
        preview.setSelectedRange(range)
        guard let manager = preview.textLayoutManager, let storage = preview.textContentStorage, let textLocation = storage.location(storage.documentRange.location, offsetBy: range.location), let laidOut = NSTextRange(location: storage.documentRange.location, end: textLocation) else { return }
        manager.ensureLayout(for: laidOut)
        let y = manager.textLayoutFragment(for: textLocation)?.layoutFragmentFrame.minY ?? 0
        previewScroll.contentView.scroll(to: NSPoint(x: 0, y: max(y + preview.textContainerInset.height - previewScroll.contentSize.height / 3, 0)))
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
