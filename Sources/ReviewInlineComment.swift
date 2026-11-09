import AppKit

final class ReviewInlineComment: NSView {
    enum Kind {
        case draft(onAdd: (String) -> Void, onCancel: () -> Void, onResize: () -> Void)
        case card(onDelete: () -> Void)
    }

    let field = ReviewCommentField(usingTextLayoutManager: false)
    private let kind: Kind
    private let header: NSTextField
    private let buttons: [NSButton]
    private let padding: CGFloat = 8
    private let headerHeight: CGFloat = 16

    init(title: String, text: String, kind: Kind, style: ReviewStyle) {
        self.kind = kind
        header = NSTextField(labelWithString: title)
        if case .draft = kind {
            buttons = [NSButton(title: "Cancel", target: nil, action: #selector(cancel)), NSButton(title: "Add Comment", target: nil, action: #selector(add))]
            buttons[1].keyEquivalent = "\r"
            buttons[1].isEnabled = false
        } else {
            buttons = [NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete Comment") ?? NSImage(), target: nil, action: #selector(delete))]
            buttons[0].isBordered = false
            buttons[0].isHidden = true
            buttons[0].toolTip = "Delete Comment"
        }
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))

        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        header.lineBreakMode = .byTruncatingTail

        field.string = text
        field.drawsBackground = false
        field.isRichText = false
        field.allowsUndo = true
        if case .card = kind { field.isEditable = false }
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = true
        field.onSubmit = { [weak self] in self?.add() }
        field.onCancel = { [weak self] in self?.cancel() }
        field.onChange = { [weak self] in self?.fieldDidChange() }

        for button in buttons {
            button.target = self
            button.controlSize = .small
            button.sizeToFit()
        }
        for view in [header, field] + buttons { addSubview(view) }
        apply(style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool { true }

    func apply(_ style: ReviewStyle) {
        appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        layer?.borderColor = style.commentBorder.cgColor
        layer?.backgroundColor = style.commentBackground.cgColor
        header.textColor = style.secondary
        if case .card = kind { buttons[0].contentTintColor = style.secondary }
        field.font = style.font
        field.textColor = style.foreground
        field.insertionPointColor = style.foreground
        field.selectedTextAttributes = [.backgroundColor: style.selection]
        field.placeholder = NSAttributedString(string: "Leave a comment", attributes: [.font: style.font, .foregroundColor: style.secondary])
        needsLayout = true
        field.needsDisplay = true
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let buttonsHeight = if case .draft = kind { 8 + (buttons.map(\.frame.height).max() ?? 0) } else { CGFloat(0) }
        return padding + headerHeight + 4 + textHeight(forWidth: width - 2 * padding) + buttonsHeight + padding
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 2 * padding
        header.frame = NSRect(x: padding, y: padding, width: width - 20, height: headerHeight)
        field.frame = NSRect(x: padding, y: padding + headerHeight + 4, width: width, height: textHeight(forWidth: width))
        guard case .draft = kind else {
            buttons[0].frame = NSRect(x: bounds.width - padding - 16, y: padding, width: 16, height: 16)
            return
        }

        let add = buttons[1].frame.size
        let cancel = buttons[0].frame.size
        buttons[1].frame = NSRect(origin: NSPoint(x: bounds.width - padding - add.width, y: bounds.height - padding - add.height), size: add)
        buttons[0].frame = NSRect(origin: NSPoint(x: buttons[1].frame.minX - 8 - cancel.width, y: bounds.height - padding - cancel.height), size: cancel)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        if case .card = kind { buttons[0].isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        if case .card = kind { buttons[0].isHidden = true }
    }

    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        guard let manager = field.layoutManager, let container = field.textContainer else { return 0 }

        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return max(manager.usedRect(for: container).height, manager.defaultLineHeight(for: field.font ?? .systemFont(ofSize: 12))).rounded(.up)
    }

    private func fieldDidChange() {
        guard case let .draft(_, _, onResize) = kind else { return }
        buttons[1].isEnabled = !field.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onResize()
    }

    @objc private func add() {
        let text = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .draft(onAdd, _, _) = kind, !text.isEmpty else { return }
        onAdd(text)
    }

    @objc private func cancel() {
        guard case let .draft(_, onCancel, _) = kind else { return }
        onCancel()
    }

    @objc private func delete() {
        guard case let .card(onDelete) = kind else { return }
        onDelete()
    }
}

final class ReviewCommentField: NSTextView {
    var placeholder: NSAttributedString?
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onChange: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        guard isEditable, !hasMarkedText() else { return super.keyDown(with: event) }

        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if [36, 76].contains(event.keyCode), flags.isEmpty {
            onSubmit()
        } else if event.keyCode == 53, flags.isEmpty {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onChange()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, isEditable, let placeholder else { return }
        placeholder.draw(at: textContainerOrigin)
    }
}
