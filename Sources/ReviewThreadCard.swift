import AppKit
import BerthCore
import QuartzCore
import SwiftUI

final class ReviewThreadCard: NSView {
    private struct Message {
        let avatar: NSTextField
        let author: NSTextField
        let time: NSTextField
        let body: NSTextField

        init(_ comment: ReviewThread.Comment?) {
            let name = comment?.author ?? "Unknown author"
            avatar = NSTextField()
            avatar.cell = VerticallyCenteredCell(textCell: String(name.prefix(1)).uppercased())
            avatar.isBezeled = false
            avatar.drawsBackground = false
            avatar.isEditable = false
            avatar.isSelectable = false
            author = NSTextField(labelWithString: name)
            time = NSTextField(labelWithString: comment?.createdAt?.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)) ?? "")
            body = NSTextField(wrappingLabelWithString: comment?.body ?? "")
            avatar.alignment = .center
            avatar.font = .systemFont(ofSize: 10, weight: .bold)
            avatar.wantsLayer = true
            avatar.layer?.cornerRadius = 11
            avatar.setAccessibilityElement(false)
            author.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            author.lineBreakMode = .byTruncatingTail
            author.toolTip = name
            time.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            time.lineBreakMode = .byTruncatingTail
            body.font = .systemFont(ofSize: NSFont.systemFontSize)
            body.isSelectable = true
        }
    }

    let thread: ReviewThread
    var isExpanded: Bool {
        didSet {
            guard isExpanded != oldValue else { return }

            measured = nil
            updateDisclosure()
        }
    }

    let replyButton = NSButton(title: "Reply", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send to Claude", target: nil, action: nil)
    private let disclosure = NSButton()
    private let accent = NSView()
    private let status: NSTextField
    private let summary: NSTextField
    private let replies: NSTextField
    private let messages: [Message]
    private let onReply: () -> Void
    private let onSend: () -> Void
    private let onToggle: (Bool) -> Void
    private let padding: CGFloat = 10
    private let headerHeight: CGFloat = 22
    private var measured: (width: CGFloat, height: CGFloat)?

    init(thread: ReviewThread, style: ReviewStyle, isExpanded: Bool, onReply: @escaping () -> Void, onSend: @escaping () -> Void, onToggle: @escaping (Bool) -> Void) {
        self.thread = thread
        self.isExpanded = isExpanded
        self.onReply = onReply
        self.onSend = onSend
        self.onToggle = onToggle
        status = NSTextField(labelWithString: thread.isResolved ? "Resolved" : thread.isOutdated ? "Outdated" : "")
        messages = thread.comments.isEmpty ? [Message(nil)] : thread.comments.map { Message($0) }
        let firstLine = thread.comments.first?.body.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        summary = NSTextField(labelWithString: firstLine)
        replies = NSTextField(labelWithString: thread.comments.count > 1 ? String(AttributedString(localized: "^[\(thread.comments.count - 1) reply](inflect: true)").characters) : "")
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        accent.wantsLayer = true
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.lineBreakMode = .byTruncatingTail
        replies.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        replies.lineBreakMode = .byTruncatingTail

        replyButton.action = #selector(reply)
        replyButton.toolTip = "Write a reply to this review thread"
        sendButton.action = #selector(send)
        sendButton.toolTip = "Paste this thread into the session prompt"
        for button in [replyButton, sendButton, disclosure] {
            button.target = self
            button.controlSize = .small
            button.sizeToFit()
        }
        disclosure.action = #selector(toggle)
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        for view in [accent, status, summary, replies, disclosure] { addSubview(view) }
        for message in messages {
            for view in [message.avatar, message.author, message.time, message.body] { addSubview(view) }
        }
        for button in [replyButton, sendButton] { addSubview(button) }
        updateDisclosure()
        apply(style)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    func apply(_ style: ReviewStyle) {
        let tint = thread.isResolved ? style.secondary : thread.isOutdated ? style.warning : style.link
        let background = style.background.blended(withFraction: thread.isResolved ? 0.03 : 0.09, of: tint) ?? style.background
        layer?.backgroundColor = background.withAlphaComponent(1).cgColor
        layer?.borderColor = style.commentBorder.cgColor
        accent.layer?.backgroundColor = tint.cgColor
        status.textColor = tint
        summary.textColor = style.secondary
        replies.textColor = style.secondary
        disclosure.contentTintColor = style.secondary
        for message in messages {
            message.avatar.layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
            message.avatar.textColor = tint
            message.author.textColor = thread.isResolved ? style.secondary : style.foreground
            message.time.textColor = style.secondary
            message.body.textColor = style.foreground
        }
    }

    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }

        let height = arrange(width: width, placesSubviews: false)
        measured = (width, height)
        return height
    }

    override func layout() {
        super.layout()
        accent.frame = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
        _ = arrange(width: bounds.width, placesSubviews: true)
    }

    private func arrange(width: CGFloat, placesSubviews: Bool) -> CGFloat {
        let inner = max(width - 2 * padding - 3, 1)
        let leading = padding + 3
        let trailing = leading + inner
        let disclosureWidth: CGFloat = 18
        let statusWidth = status.stringValue.isEmpty ? 0 : status.intrinsicContentSize.width + 6
        if !isExpanded {
            arrangeCollapsed(leading: leading, trailing: trailing - disclosureWidth - statusWidth, placesSubviews: placesSubviews)
            if placesSubviews {
                status.frame = NSRect(x: trailing - statusWidth - disclosureWidth, y: padding + 3, width: statusWidth, height: 16)
                disclosure.frame = NSRect(x: trailing - disclosureWidth, y: padding, width: disclosureWidth, height: headerHeight)
            }
            return padding + headerHeight + padding
        }

        var top = padding
        for (index, message) in messages.enumerated() {
            let metadataEnd = trailing - (index == 0 ? statusWidth + disclosureWidth : 0)
            let authorStart = leading + headerHeight + 6
            let metadataWidth = max(metadataEnd - authorStart, 0)
            let preferredTimeWidth = message.time.stringValue.isEmpty ? 0 : message.time.attributedStringValue.size().width.rounded(.up) + 4
            let wrapsTime = preferredTimeWidth > 0 && metadataWidth < preferredTimeWidth + 34
            let timeWidth = min(preferredTimeWidth, wrapsTime ? trailing - authorStart : metadataWidth)
            if placesSubviews {
                message.avatar.frame = NSRect(x: leading, y: top, width: headerHeight, height: headerHeight)
                message.author.frame = NSRect(x: authorStart, y: top + 3, width: max(metadataWidth - (wrapsTime ? 0 : timeWidth + 4), 0), height: 16)
                message.time.frame = NSRect(x: wrapsTime ? authorStart : metadataEnd - timeWidth, y: top + (wrapsTime ? headerHeight : 3), width: timeWidth, height: 16)
                message.time.toolTip = timeWidth < preferredTimeWidth ? message.time.stringValue : nil
                if index == 0 {
                    status.frame = NSRect(x: trailing - statusWidth - disclosureWidth, y: top + 3, width: statusWidth, height: 16)
                    disclosure.frame = NSRect(x: trailing - disclosureWidth, y: top, width: disclosureWidth, height: headerHeight)
                }
            }
            top += headerHeight + (wrapsTime ? 16 : 0)
            if !message.body.stringValue.isEmpty {
                top += 4
                let proposed = NSRect(x: leading, y: top, width: inner, height: .greatestFiniteMagnitude)
                let height = (message.body.cell?.cellSize(forBounds: proposed).height ?? 0).rounded(.up)
                if placesSubviews { message.body.frame = NSRect(x: leading, y: top, width: inner, height: height) }
                top += height
            }
            if index < messages.count - 1 { top += 10 }
        }

        let reply = replyButton.frame.size
        let send = sendButton.frame.size
        let wraps = reply.width + 6 + send.width > inner
        top += 8
        if placesSubviews {
            replyButton.frame.origin = NSPoint(x: leading, y: top)
            sendButton.frame.origin = NSPoint(x: wraps ? leading : leading + reply.width + 6, y: top + (wraps ? reply.height + 4 : 0))
        }
        top += wraps ? reply.height + 4 + send.height : max(reply.height, send.height)
        return top + padding
    }

    private func arrangeCollapsed(leading: CGFloat, trailing: CGFloat, placesSubviews: Bool) {
        guard placesSubviews, let message = messages.first else { return }

        let authorStart = leading + headerHeight + 6
        let timeWidth = message.time.attributedStringValue.size().width.rounded(.up) + 4
        let repliesWidth = replies.stringValue.isEmpty ? 0 : replies.attributedStringValue.size().width.rounded(.up) + 4
        let timeStart = trailing - timeWidth
        let repliesStart = timeStart - (repliesWidth > 0 ? repliesWidth + 8 : 0)
        let authorWidth = min(message.author.attributedStringValue.size().width.rounded(.up) + 4, max(repliesStart - authorStart - 8, 0))
        let summaryStart = authorStart + authorWidth + 8
        message.avatar.frame = NSRect(x: leading, y: padding, width: headerHeight, height: headerHeight)
        message.author.frame = NSRect(x: authorStart, y: padding + 3, width: authorWidth, height: 16)
        summary.frame = NSRect(x: summaryStart, y: padding + 3, width: max(repliesStart - 8 - summaryStart, 0), height: 16)
        replies.frame = NSRect(x: repliesStart, y: padding + 3, width: repliesWidth, height: 16)
        message.time.frame = NSRect(x: timeStart, y: padding + 3, width: timeWidth, height: 16)
    }

    private func updateDisclosure() {
        let title = isExpanded ? "Collapse thread" : "Expand thread"
        disclosure.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: title)
        disclosure.setAccessibilityLabel(title)
        disclosure.toolTip = title
        for (index, message) in messages.enumerated() {
            for view in [message.avatar, message.author, message.time] { view.isHidden = !isExpanded && index != 0 }
            message.body.isHidden = !isExpanded
        }
        summary.isHidden = isExpanded
        replies.isHidden = isExpanded
        for button in [replyButton, sendButton] { button.isHidden = !isExpanded }
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !isExpanded || point.y < padding + headerHeight else { return super.mouseDown(with: event) }

        toggle()
    }

    @objc private func toggle() {
        onToggle(!isExpanded)
    }

    @objc private func reply() {
        onReply()
    }

    @objc private func send() {
        onSend()
    }
}

struct ReviewCommentCollapse {
    var overrides: [String: Bool] = [:]
    var all: Bool?

    func isCollapsed(_ id: String, default fallback: Bool) -> Bool {
        overrides[id] ?? all ?? fallback
    }

    mutating func set(all isCollapsed: Bool) {
        overrides = [:]
        all = isCollapsed
    }
}

private final class VerticallyCenteredCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        let height = cellSize(forBounds: rect).height
        return NSRect(x: base.minX, y: base.minY + (base.height - height) / 2, width: base.width, height: height)
    }
}

struct ReviewThreadRows: View {
    let threads: [ReviewThread]
    let open: (ReviewThread) -> Void
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let groups = Dictionary(grouping: threads, by: \.path)
        ForEach(groups.keys.sorted(), id: \.self) { path in
            let file = path as NSString
            let group = groups[path, default: []]
            HStack(spacing: 5) {
                Text(file.lastPathComponent).bold()
                if !file.deletingLastPathComponent.isEmpty {
                    Text(file.deletingLastPathComponent)
                        .foregroundStyle(theme.secondary)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .help(path)
            .reviewRow(top: 5, bottom: 2)
            ForEach(group.filter { !$0.isResolved } + group.filter(\.isResolved)) { thread in
                Button { open(thread) } label: {
                    row(thread)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(thread.line.map { "Open \(path) at line \($0)" } ?? "Open \(path)")
                .reviewRow(top: 4, bottom: 4)
            }
        }
    }

    private func row(_ thread: ReviewThread) -> some View {
        let first = thread.comments.first
        let author = first?.author ?? "Unknown author"
        let tint = thread.isResolved ? theme.secondary : theme.branch
        return HStack(alignment: .top, spacing: 7) {
            Text(String(author.prefix(1)).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.16), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(author).fontWeight(.semibold).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("^[\(max(0, thread.comments.count - 1)) reply](inflect: true)")
                        .monospacedDigit()
                        .foregroundStyle(theme.secondary)
                    if thread.isResolved {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(theme.working)
                            .accessibilityLabel("Resolved")
                            .help("Resolved")
                    }
                    if thread.isOutdated {
                        Text("Outdated")
                            .foregroundStyle(theme.needsYou)
                            .padding(.horizontal, 4)
                            .background(theme.needsYou.opacity(0.16), in: .rect(cornerRadius: 4))
                    }
                }
                .font(.caption)
                Text(first?.body.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? "")
                    .font(.callout)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(2)
            }
        }
    }
}
