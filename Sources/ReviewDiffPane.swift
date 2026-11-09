import BerthCore
import SwiftUI

struct ReviewDiffPane: View {
    let path: String
    let contents: ReviewContents
    @Binding var draft: String?
    @Binding var comments: [ReviewComment]
    let style: ReviewStyle
    @AppStorage(ReviewStyle.showsMinimapKey) private var showsMinimap = true
    @State private var analysis: ReviewDiffAnalysis?

    var body: some View {
        if let unavailable = [contents.original, contents.modified].compactMap(\.self).first(where: { if case .text = $0 { false } else { true } }) {
            ContentUnavailableView {
                Label(unavailable == .binary ? "Binary File" : "Too Large to Show", systemImage: "doc")
            } description: {
                if case let .tooLarge(bytes) = unavailable { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let original = if case let .text(text)? = contents.original { text } else { "" }
            let loaded = if case let .text(text)? = contents.modified { text } else { "" }
            let modified = draft ?? loaded
            ReviewDiffViews(
                path: path,
                original: original,
                modified: modified,
                isOriginalAbsent: contents.original == nil,
                isModifiedAbsent: contents.modified == nil,
                analysis: analysis,
                style: style,
                showsMinimap: showsMinimap,
                comments: $comments,
                onEdit: { draft = $0 == loaded ? nil : $0 }
            )
            .task(id: [original, modified]) {
                if analysis != nil { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }

                let computed = await Task.detached { ReviewDiffAnalysis(original: original, modified: modified, path: path) }.value
                guard !Task.isCancelled else { return }
                analysis = computed
            }
        }
    }
}

nonisolated struct ReviewDiffAnalysis: Sendable {
    let id = UUID()
    let original: String
    let modified: String
    let diff: ReviewDiff
    let originalRuns: [ReviewHighlighter.Span]
    let modifiedRuns: [ReviewHighlighter.Span]

    init(original: String, modified: String, path: String) {
        self.original = original
        self.modified = modified
        diff = ReviewDiff(original: original, modified: modified)
        originalRuns = Self.runs(ReviewHighlighter.spans(in: original, path: path), length: original.utf16.count)
        modifiedRuns = Self.runs(ReviewHighlighter.spans(in: modified, path: path), length: modified.utf16.count)
    }

    static func runs(_ spans: [ReviewHighlighter.Span], length: Int) -> [ReviewHighlighter.Span] {
        var owners = [Int32](repeating: -1, count: length)
        for (index, span) in spans.enumerated() where span.range.location < length {
            for offset in span.range.location..<min(NSMaxRange(span.range), length) { owners[offset] = Int32(index) }
        }

        var runs: [ReviewHighlighter.Span] = []
        var start = 0
        for offset in 0...length where offset == length || owners[offset] != owners[start] {
            if start < length, owners[start] >= 0 { runs.append(ReviewHighlighter.Span(range: NSRange(location: start, length: offset - start), capture: spans[Int(owners[start])].capture)) }
            start = offset
        }
        return runs
    }
}

private struct ReviewDiffViews: NSViewRepresentable {
    let path: String
    let original: String
    let modified: String
    let isOriginalAbsent: Bool
    let isModifiedAbsent: Bool
    let analysis: ReviewDiffAnalysis?
    let style: ReviewStyle
    let showsMinimap: Bool
    @Binding var comments: [ReviewComment]
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        let stack = NSStackView(views: coordinator.makeSide(coordinator.left) + coordinator.makeSide(coordinator.right) + [coordinator.minimap, coordinator.ruler])
        stack.spacing = 0
        stack.views[1].widthAnchor.constraint(equalTo: stack.views[3].widthAnchor).isActive = true
        coordinator.minimap.original = coordinator.left
        coordinator.minimap.modified = coordinator.right
        coordinator.ruler.original = coordinator.left
        coordinator.ruler.modified = coordinator.right
        for view in [coordinator.minimap, coordinator.ruler] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        stack.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let left = ReviewTextView(usingTextLayoutManager: true)
        let right = ReviewTextView(usingTextLayoutManager: true)
        let minimap = ReviewMinimap()
        let ruler = ReviewOverviewRuler()
        private let undoManager = UndoManager()
        private var parent: ReviewDiffViews?
        private var loadedOriginal: String?
        private var loadedModified: String?
        private var applied: ReviewDiffAnalysis?
        private var cards: [String: ReviewInlineComment] = [:]
        private var draft: (view: ReviewInlineComment, owner: ReviewTextView, row: Int)?

        func makeSide(_ textView: ReviewTextView) -> [NSView] {
            let scrollView = NSScrollView()
            let gutter = ReviewGutter()
            textView.kind = textView === left ? .original : .modified
            textView.delegate = self
            textView.textContentStorage?.delegate = textView
            textView.textLayoutManager?.renderingAttributesValidator = { [weak textView] _, fragment in textView?.colorSyntax(in: fragment) }
            textView.isEditable = false
            textView.isRichText = false
            textView.usesRuler = false
            textView.allowsUndo = true
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isAutomaticTextCompletionEnabled = false
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = textView.maxSize

            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.findBarPosition = .belowContent
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidResize), name: NSView.frameDidChangeNotification, object: scrollView.contentView)

            gutter.textView = textView
            gutter.drawsSeparator = textView === right
            gutter.setContentHuggingPriority(.required, for: .horizontal)
            gutter.setContentCompressionResistancePriority(.required, for: .horizontal)
            textView.gutter = gutter
            gutter.onSelect = { [weak self, weak textView] lines in
                guard let self, let textView else { return }
                comment(on: textView, lines: lines)
            }
            return [gutter, scrollView]
        }

        func update(_ view: ReviewDiffViews) {
            parent = view
            minimap.isHidden = !view.showsMinimap
            right.isEditable = !view.isModifiedAbsent
            left.isAbsent = view.isOriginalAbsent
            right.isAbsent = view.isModifiedAbsent

            let isStyleChanged = view.style != left.style
            let isOriginalChanged = view.original != loadedOriginal
            let isModifiedChanged = view.modified != loadedModified
            if isOriginalChanged {
                loadedOriginal = view.original
                left.string = view.original
                left.side = nil
                left.syntaxRuns = []
            }
            if isModifiedChanged {
                loadedModified = view.modified
                right.string = view.modified
                right.side = nil
                right.syntaxRuns = []
                undoManager.removeAllActions()
            }

            let analysis = view.analysis.flatMap { $0.id != applied?.id && $0.original == loadedOriginal && $0.modified == loadedModified ? $0 : nil }
            if let analysis {
                applied = analysis
                left.side = analysis.diff.original
                left.syntaxRuns = analysis.originalRuns
                right.side = analysis.diff.modified
                right.syntaxRuns = analysis.modifiedRuns
            }
            if isStyleChanged {
                left.style = view.style
                right.style = view.style
                for inline in Array(cards.values) + [draft?.view].compactMap(\.self) { inline.apply(view.style) }
            }
            if isStyleChanged || isOriginalChanged || isModifiedChanged || analysis != nil {
                reload()
            }
            layoutInline()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ReviewTextView, textView === right else { return }
            loadedModified = textView.string
            parent?.onEdit(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? ReviewTextView)?.gutter?.needsDisplay = true
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        @objc private func clipViewDidScroll(_ notification: Notification) {
            left.gutter?.needsDisplay = true
            right.gutter?.needsDisplay = true
            minimap.needsDisplay = true
            ruler.needsDisplay = true
            layoutInline()
            guard let source = notification.object as? NSClipView, let target = [left, right].compactMap(\.enclosingScrollView).first(where: { $0.contentView !== source }), target.contentView.bounds.minY != source.bounds.minY else { return }

            target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: source.bounds.minY))
            target.reflectScrolledClipView(target.contentView)
        }

        @objc private func clipViewDidResize(_ notification: Notification) {
            minimap.needsDisplay = true
            ruler.needsDisplay = true
            layoutInline()
        }

        private func reload() {
            left.refresh()
            right.refresh()
            documentsDidResize()
        }

        private func documentsDidResize() {
            for (textView, partner) in [(left, right), (right, left)] where textView.isAbsent {
                textView.minimumHeight = (partner.textLayoutManager?.usageBoundsForTextContainer.height ?? 0) + 2 * partner.textContainerInset.height
                textView.setFrameSize(NSSize(width: textView.frame.width, height: textView.minSize.height))
            }
            minimap.invalidate()
            ruler.needsDisplay = true
        }

        private func layoutInline() {
            guard let parent else { return }

            let comments = parent.comments.filter { $0.path == parent.path }
            for (id, card) in cards where !comments.contains(where: { $0.id == id }) {
                card.removeFromSuperview()
                cards[id] = nil
            }
            var placed: [(view: ReviewInlineComment, owner: ReviewTextView, row: Int)] = []
            for comment in comments {
                let owner = comment.side == .original ? left : right
                let numbers = comment.endLine > comment.line ? "Lines \(comment.line)–\(comment.endLine)" : "Line \(comment.line)"
                let card = cards[comment.id] ?? ReviewInlineComment(title: comment.side == .original ? "Removed \(numbers)" : numbers, text: comment.text, kind: .card(onDelete: { [weak self] in self?.parent?.comments.removeAll { $0.id == comment.id } }), style: owner.style)
                cards[comment.id] = card
                if card.superview == nil { owner.addSubview(card) }
                let rows = owner.side?.rows ?? []
                card.isHidden = !rows.indices.contains(comment.endLine - 1)
                if !card.isHidden { placed.append((card, owner, rows[comment.endLine - 1])) }
            }
            placed += [draft].compactMap(\.self)

            let inset: CGFloat = 6
            let indent = right.textContainerOrigin.x + (right.textContainer?.lineFragmentPadding ?? 0)
            let width = max((right.enclosingScrollView?.contentView.bounds.width ?? 0) - indent - 2 * inset, 200)
            let heights = placed.map { $0.view.fittingHeight(forWidth: width) }
            var reserved: [Int: CGFloat] = [:]
            for (item, height) in zip(placed, heights) { reserved[item.row, default: 0] += height + inset * 2 }
            reserved = reserved.mapValues { $0.rounded(.up) }
            if reserved != right.reserved {
                left.reserved = reserved
                right.reserved = reserved
                documentsDidResize()
            }

            var stacked: [Int: CGFloat] = [:]
            for (item, height) in zip(placed, heights) {
                let top = item.owner.top(ofRow: item.row + 1) - reserved[item.row, default: 0] + stacked[item.row, default: 0] + inset
                stacked[item.row, default: 0] += height + inset * 2
                item.view.frame = NSRect(x: item.owner.visibleRect.minX + indent, y: top, width: width, height: height)
            }
        }

        private func comment(on textView: ReviewTextView, lines: ClosedRange<Int>) {
            guard let rows = textView.side?.rows, rows.indices.contains(lines.upperBound) else { return }

            let isRemoval = textView === left && lines.contains { left.side?.changedLines.contains($0) == true }
            let owner = textView === left && !isRemoval ? right : textView
            let ownerRows = owner.side?.rows ?? []
            let first = owner === textView ? lines.lowerBound : ownerRows.partitioningIndex { $0 >= rows[lines.lowerBound] }
            let last = owner === textView ? lines.upperBound : ownerRows.partitioningIndex { $0 >= rows[lines.upperBound] }
            let source = (isRemoval ? loadedOriginal : loadedModified) ?? ""
            let texts = source.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(first).prefix(last - first + 1)
            let snippet = texts.map { isRemoval ? "-\($0)" : String($0) }.joined(separator: "\n")
            let numbers = last > first ? "Lines \(first + 1)–\(last + 1)" : "Line \(first + 1)"
            let path = parent?.path ?? ""

            let other = textView === left ? right : left
            draft?.view.removeFromSuperview()
            other.selectedLines = nil
            other.needsDisplay = true
            let view = ReviewInlineComment(title: isRemoval ? "Removed \(numbers)" : numbers, text: "", kind: .draft(
                onAdd: { [weak self] text in
                    self?.parent?.comments.append(ReviewComment(id: UUID().uuidString, path: path, line: first + 1, endLine: last + 1, text: text, snippet: snippet, side: isRemoval ? .original : .modified))
                    self?.closeDraft()
                },
                onCancel: { [weak self] in self?.closeDraft() },
                onResize: { [weak self] in self?.layoutInline() }
            ), style: owner.style)
            owner.addSubview(view)
            draft = (view, owner, rows[lines.upperBound])
            layoutInline()
            owner.window?.makeFirstResponder(view.field)
            owner.scrollToVisible(NSRect(x: owner.visibleRect.minX, y: view.frame.minY, width: 1, height: view.frame.height))
        }

        private func closeDraft() {
            guard let draft else { return }

            if draft.owner.window?.firstResponder === draft.view.field { draft.owner.window?.makeFirstResponder(draft.owner) }
            draft.view.removeFromSuperview()
            self.draft = nil
            for textView in [left, right] {
                textView.selectedLines = nil
                textView.needsDisplay = true
                textView.gutter?.needsDisplay = true
            }
            layoutInline()
        }
    }
}
