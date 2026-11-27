import AppKit

final class ReviewInlineComment: NSView {
    enum Kind {
        case draft(onAdd: (String) -> Void, onCancel: () -> Void, onResize: () -> Void)
        case card(onEdit: () -> Void, onDelete: () -> Void, onToggle: (Bool) -> Void)
    }

    let field = ReviewCommentField(usingTextLayoutManager: false)
    private let kind: Kind
    let header: NSTextField
    private let summary = NSTextField(labelWithString: "")
    private let disclosure = NSButton()
    private let buttons: [NSButton]
    private var restingBackground: CGColor?
    private var hoverBackground: CGColor?
    private let padding: CGFloat = 8
    private let headerHeight: CGFloat = 16
    private var pullRequestItem: NSMenuItem?
    var onSendToPullRequest: (() -> Void)? {
        didSet { pullRequestItem?.isEnabled = onSendToPullRequest != nil }
    }

    var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }

            updateDisclosure()
        }
    }

    var isSubmitting = false {
        didSet {
            field.isEditable = !isSubmitting
            buttons[0].isEnabled = !isSubmitting
            buttons[1].isEnabled = !isSubmitting && !field.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    init(title: String, text: String, kind: Kind, style: ReviewStyle, submitTitle: String? = nil) {
        self.kind = kind
        header = NSTextField(labelWithString: title)
        if case .draft = kind {
            buttons = [NSButton(title: "Cancel", target: nil, action: #selector(cancel)), NSButton(title: submitTitle ?? (text.isEmpty ? "Add Comment" : "Save"), target: nil, action: #selector(add))]
            buttons[1].keyEquivalent = submitTitle == nil ? "\r" : ""
            buttons[1].isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if submitTitle != nil { buttons[1].toolTip = "Add to your pending review, then submit the review on GitHub" }
        } else {
            let delete = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete Comment") ?? NSImage(), target: nil, action: #selector(delete))
            delete.isBordered = false
            delete.isHidden = true
            delete.toolTip = "Delete Comment"
            buttons = [delete]
        }
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))

        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        header.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.lineBreakMode = .byTruncatingTail
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.controlSize = .small

        field.string = text
        field.drawsBackground = false
        field.isRichText = false
        field.allowsUndo = true
        field.writingToolsBehavior = .none
        if case .card = kind { field.isEditable = false }
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = false
        field.onSubmit = { [weak self] in self?.add() }
        field.submitsOnReturn = submitTitle == nil
        field.onCancel = { [weak self] in self?.cancel() }
        field.onChange = { [weak self] in self?.fieldDidChange() }
        field.onClick = { [weak self] in self?.edit() }
        if case .card = kind {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "Edit Comment", action: #selector(edit), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Copy Comment", action: #selector(copyText), keyEquivalent: "").target = self
            menu.addItem(.separator())
            let send = menu.addItem(withTitle: "Add to Pull Request Review", action: #selector(sendToPullRequest), keyEquivalent: "")
            send.target = self
            send.isEnabled = false
            send.toolTip = "Add to your pending review, then submit the review on GitHub"
            pullRequestItem = send
            self.menu = menu
            field.menu = menu
        }

        for button in buttons {
            button.target = self
            button.controlSize = .small
            button.sizeToFit()
        }
        for view in [header, field] + buttons { addSubview(view) }
        if case .card = kind {
            addSubview(summary)
            addSubview(disclosure)
            updateDisclosure()
        }
        apply(style)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    func apply(_ style: ReviewStyle) {
        appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        layer?.borderColor = style.commentBorder.cgColor
        restingBackground = style.commentBackground.cgColor
        hoverBackground = style.commentBackground.blended(withFraction: 0.1, of: style.foreground)?.cgColor
        layer?.backgroundColor = restingBackground
        header.textColor = style.secondary
        summary.textColor = style.secondary
        disclosure.contentTintColor = style.secondary
        if case .card = kind { buttons.forEach { $0.contentTintColor = style.secondary } }
        field.font = style.font
        field.textColor = style.foreground
        field.insertionPointColor = style.foreground
        field.selectedTextAttributes = [.backgroundColor: style.selection]
        field.placeholder = NSAttributedString(string: field.submitsOnReturn ? "Leave a comment" : "Leave a reply", attributes: [.font: style.font, .foregroundColor: style.secondary])
        needsLayout = true
        field.needsDisplay = true
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed { return padding + headerHeight + padding }

        let buttonsHeight = if case .draft = kind { 8 + (buttons.map(\.frame.height).max() ?? 0) } else { CGFloat(0) }
        return padding + headerHeight + 4 + textHeight(forWidth: width - 2 * padding) + buttonsHeight + padding
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 2 * padding
        guard case .draft = kind else {
            let trailing = bounds.width - padding - 16
            summary.stringValue = field.string.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let headerWidth = min(header.attributedStringValue.size().width.rounded(.up) + 4, width / 2)
            disclosure.frame = NSRect(x: trailing, y: padding, width: 16, height: 16)
            buttons[0].frame = NSRect(x: trailing - 20, y: padding, width: 16, height: 16)
            header.frame = NSRect(x: padding, y: padding, width: isCollapsed ? headerWidth : trailing - 24 - padding, height: headerHeight)
            summary.frame = NSRect(x: padding + headerWidth + 8, y: padding, width: max(trailing - 24 - padding - headerWidth - 8, 0), height: headerHeight)
            field.frame = NSRect(x: padding, y: padding + headerHeight + 4, width: width, height: isCollapsed ? 0 : textHeight(forWidth: width))
            return
        }

        header.frame = NSRect(x: padding, y: padding, width: width - 24, height: headerHeight)
        field.frame = NSRect(x: padding, y: padding + headerHeight + 4, width: width, height: textHeight(forWidth: width))

        let add = buttons[1].frame.size
        let cancel = buttons[0].frame.size
        buttons[1].frame = NSRect(origin: NSPoint(x: bounds.width - padding - add.width, y: bounds.height - padding - add.height), size: add)
        buttons[0].frame = NSRect(origin: NSPoint(x: buttons[1].frame.minX - 8 - cancel.width, y: bounds.height - padding - cancel.height), size: cancel)
    }

    override func mouseDown(with event: NSEvent) {
        guard case .card = kind else {
            window?.makeFirstResponder(field)
            return
        }

        if isCollapsed || convert(event.locationInWindow, from: nil).y < padding + headerHeight { return toggle() }
        edit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with _: NSEvent) {
        guard case .card = kind else { return }

        buttons.forEach { $0.isHidden = false }
        layer?.backgroundColor = hoverBackground
    }

    override func mouseExited(with _: NSEvent) {
        guard case .card = kind else { return }

        buttons.forEach { $0.isHidden = true }
        layer?.backgroundColor = restingBackground
    }

    private func updateDisclosure() {
        let title = isCollapsed ? "Expand comment" : "Collapse comment"
        disclosure.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: title)
        disclosure.setAccessibilityLabel(title)
        disclosure.toolTip = title
        summary.isHidden = !isCollapsed
        field.isHidden = isCollapsed
        needsLayout = true
    }

    @objc private func toggle() {
        guard case let .card(_, _, onToggle) = kind else { return }

        onToggle(!isCollapsed)
    }

    @objc private func sendToPullRequest() {
        onSendToPullRequest?()
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(field.string, forType: .string)
    }

    private func textHeight(forWidth width: CGFloat) -> CGFloat {
        // swiftlint:disable:next text_kit_1_layout_manager - the field is built with usingTextLayoutManager: false
        guard let manager = field.layoutManager, let container = field.textContainer else { return 0 }

        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return max(manager.usedRect(for: container).height, manager.defaultLineHeight(for: field.font ?? .systemFont(ofSize: 12))).rounded(.up)
    }

    private func fieldDidChange() {
        guard case let .draft(_, _, onResize) = kind else { return }

        buttons[1].isEnabled = !isSubmitting && !field.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onResize()
    }

    @objc private func add() {
        guard !isSubmitting, case let .draft(onAdd, _, _) = kind else { return }

        onAdd(field.string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func cancel() {
        guard !isSubmitting, case let .draft(_, onCancel, _) = kind else { return }

        onCancel()
    }

    @objc private func edit() {
        guard case let .card(onEdit, _, _) = kind else { return }

        buttons.forEach { $0.isHidden = true }
        layer?.backgroundColor = restingBackground
        onEdit()
    }

    @objc private func delete() {
        guard case let .card(_, onDelete, _) = kind else { return }

        onDelete()
    }
}

final class ReviewCommentField: NSTextView {
    var placeholder: NSAttributedString?
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onChange: () -> Void = {}
    var onClick: () -> Void = {}
    var submitsOnReturn = true

    override func resetCursorRects() {
        if !isEditable { return addCursorRect(bounds, cursor: .arrow) }

        super.resetCursorRects()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        isEditable ? super.menu(for: event) : menu
    }

    override func mouseDown(with event: NSEvent) {
        if !isEditable { return onClick() }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable, !hasMarkedText() else { return super.keyDown(with: event) }

        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if submitsOnReturn, [36, 76].contains(event.keyCode), flags.isEmpty {
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
