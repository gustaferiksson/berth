import BerthCore
import SwiftUI

struct ReviewDiffPane: View {
    let path: String
    let compare: ReviewCompare?
    let contents: ReviewContents
    let editor: ReviewTextView?
    @Binding var draft: String?
    @Binding var comments: [ReviewComment]
    let threads: [ReviewThread]
    @Binding var replyDrafts: [String: String]
    let isWritingPullRequest: Bool
    let style: ReviewStyle
    let language: ReviewLanguage?
    let reveal: LanguageServerRange?
    let revealLine: (line: Int, side: ReviewComment.Side)?
    let isUnified: Bool
    let takesFocus: Bool
    let changeStep: Int?
    let onRevealed: () -> Void
    let onLineRevealed: () -> Void
    let onChangeStepped: () -> Void
    let editsComment: String?
    let onEditing: () -> Void
    let onDefinition: (LanguageServerLocation, LanguageServerRange) -> Void
    let onReply: (String, String) async -> Bool
    let onSendThread: (ReviewThread) -> Void
    let onSendComment: ((ReviewComment) -> Void)?
    let workingText: () -> String?
    @AppStorage(ReviewStyle.showsMinimapKey) private var showsMinimap = true
    @AppStorage(LanguageServerEntry.storageKey) private var configuredServers = ""
    @AppStorage("reviewSplitRatio") private var splitRatio = 0.5
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
                compare: compare,
                editor: editor,
                original: original,
                modified: modified,
                isOriginalAbsent: contents.original == nil,
                isModifiedAbsent: contents.modified == nil,
                analysis: analysis,
                style: style,
                showsMinimap: showsMinimap,
                comments: $comments,
                threads: threads,
                replyDrafts: $replyDrafts,
                isWritingPullRequest: isWritingPullRequest,
                language: contents.modified == nil ? nil : language,
                diagnostics: contents.modified == nil || editor == nil && compare == .committed ? [] : language?.diagnostics(for: path) ?? [],
                reveal: reveal,
                revealLine: revealLine,
                isUnified: isUnified,
                splitRatio: splitRatio,
                takesFocus: takesFocus,
                changeStep: changeStep,
                onRevealed: onRevealed,
                onLineRevealed: onLineRevealed,
                onChangeStepped: onChangeStepped,
                editsComment: editsComment,
                onEditing: onEditing,
                onDefinition: onDefinition,
                onReply: onReply,
                onSendThread: onSendThread,
                onSendComment: onSendComment,
                workingText: workingText,
                onEdit: { draft = $0 == loaded ? nil : $0 },
                onSplit: { splitRatio = $0 }
            )
            .task(id: [original, modified, configuredServers]) {
                if analysis != nil { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }

                let base = compare == nil ? modified : original
                let computed = await Task.detached { ReviewDiffAnalysis(original: original, modified: modified, base: base, path: path) }.value
                guard !Task.isCancelled else { return }

                analysis = computed
                if contents.modified != nil, let text = editor == nil && compare == .committed ? workingText() : modified { await language?.sync(path, text: text) }
            }
            .onChange(of: language == nil) {
                Task { if contents.modified != nil, let text = editor == nil && compare == .committed ? workingText() : modified { await language?.sync(path, text: text) } }
            }
        }
    }
}

nonisolated struct ReviewDiffAnalysis: Sendable {
    let id = UUID()
    let original: String
    let modified: String
    let diff: ReviewDiff
    let originalRuns: [CodeHighlighter.Span]
    let modifiedRuns: [CodeHighlighter.Span]

    init(original: String, modified: String, base: String, path: String) {
        self.original = original
        self.modified = modified
        diff = ReviewDiff(original: base, modified: modified)
        originalRuns = Self.runs(CodeHighlighter.spans(in: original, language: path), length: original.utf16.count)
        modifiedRuns = Self.runs(CodeHighlighter.spans(in: modified, language: path), length: modified.utf16.count)
    }

    static func runs(_ spans: [CodeHighlighter.Span], length: Int) -> [CodeHighlighter.Span] {
        var owners = [Int32](repeating: -1, count: length)
        for (index, span) in spans.enumerated() where span.range.location < length {
            for offset in span.range.location..<min(NSMaxRange(span.range), length) { owners[offset] = Int32(index) }
        }

        var runs: [CodeHighlighter.Span] = []
        var start = 0
        for offset in 0...length where offset == length || owners[offset] != owners[start] {
            if start < length, owners[start] >= 0 { runs.append(CodeHighlighter.Span(range: NSRange(location: start, length: offset - start), capture: spans[Int(owners[start])].capture)) }
            start = offset
        }
        return runs
    }
}

private struct ReviewDiffViews: NSViewRepresentable {
    let path: String
    let compare: ReviewCompare?
    let editor: ReviewTextView?
    let original: String
    let modified: String
    let isOriginalAbsent: Bool
    let isModifiedAbsent: Bool
    let analysis: ReviewDiffAnalysis?
    let style: ReviewStyle
    let showsMinimap: Bool
    @Binding var comments: [ReviewComment]
    let threads: [ReviewThread]
    @Binding var replyDrafts: [String: String]
    let isWritingPullRequest: Bool
    let language: ReviewLanguage?
    let diagnostics: [LanguageServerDiagnostic]
    let reveal: LanguageServerRange?
    let revealLine: (line: Int, side: ReviewComment.Side)?
    let isUnified: Bool
    let splitRatio: Double
    let takesFocus: Bool
    let changeStep: Int?
    let onRevealed: () -> Void
    let onLineRevealed: () -> Void
    let onChangeStepped: () -> Void
    let editsComment: String?
    let onEditing: () -> Void
    let onDefinition: (LanguageServerLocation, LanguageServerRange) -> Void
    let onReply: (String, String) async -> Bool
    let onSendThread: (ReviewThread) -> Void
    let onSendComment: ((ReviewComment) -> Void)?
    let workingText: () -> String?
    let onEdit: (String) -> Void
    let onSplit: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(right: editor ?? ReviewTextView(usingTextLayoutManager: true))
    }

    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        let rightPane = NSStackView(views: coordinator.makeSide(coordinator.right))
        coordinator.makeSide(coordinator.left).forEach(coordinator.leftPane.addArrangedSubview)
        for pane in [coordinator.leftPane, rightPane] {
            pane.spacing = 0
            coordinator.split.addSubview(pane)
        }
        let stack = NSStackView(views: [coordinator.split, coordinator.minimap, coordinator.ruler])
        stack.spacing = 0
        coordinator.minimap.original = coordinator.left
        coordinator.minimap.modified = coordinator.right
        coordinator.ruler.original = coordinator.left
        coordinator.ruler.modified = coordinator.right
        for view in [coordinator.minimap, coordinator.ruler] {
            view.clipsToBounds = true
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        stack.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
        context.coordinator.update(self)
    }

    static func dismantleNSView(_: NSStackView, coordinator: Coordinator) {
        coordinator.cards.values.forEach { $0.removeFromSuperview() }
        coordinator.threadCards.values.forEach { $0.removeFromSuperview() }
        [coordinator.draft?.view, coordinator.peek?.view].compactMap(\.self).forEach { $0.removeFromSuperview() }
        guard coordinator.right.delegate === coordinator else { return }

        coordinator.right.selectedLines = nil
        coordinator.right.unifiedOriginal = nil
        coordinator.right.minimumWidth = 0
        coordinator.right.reserved = [:]
        coordinator.right.dismissHover()
        coordinator.right.onHover = nil
        coordinator.right.onDefinition = nil
        coordinator.right.onReferences = nil
        coordinator.right.focusesInWindow = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSSplitViewDelegate {
        let left = ReviewTextView(usingTextLayoutManager: true)
        let right: ReviewTextView
        let split = ReviewSplitView()
        let leftPane = NSStackView()
        let minimap = ReviewMinimap()
        let ruler = ReviewOverviewRuler()
        private var parent: ReviewDiffViews?
        private var loadedOriginal: String?
        private var loadedModified: String?
        private var applied: ReviewDiffAnalysis?
        var cards: [String: ReviewInlineComment] = [:]
        var threadCards: [String: ReviewThreadCard] = [:]
        var draft: (view: ReviewInlineComment, numbered: ReviewTextView, line: Int, editing: String?, replyingTo: String?)?
        var peek: (view: ReviewReferencesPeek, numbered: ReviewTextView, line: Int)?

        init(right: ReviewTextView) {
            self.right = right
            loadedModified = right.string
            super.init()
            split.isVertical = true
            split.dividerStyle = .thin
            split.delegate = self
            split.onDrag = { [weak self] ratio in self?.parent?.onSplit(ratio) }
        }

        func makeSide(_ textView: ReviewTextView) -> [NSView] {
            let scrollView = OverlayScrollView()
            let gutter = ReviewGutter()
            textView.kind = textView === left ? .original : .modified
            textView.delegate = self
            textView.textContentStorage?.delegate = textView
            if let manager = textView.textLayoutManager, !(manager is ReviewTextLayoutManager) { object_setClass(manager, ReviewTextLayoutManager.self) }
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
            textView.writingToolsBehavior = .none
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = textView.maxSize
            // TextKit 2 puts the container origin at -lineFragmentPadding, and NSTextView's end-of-live-resize re-anchor then scrolls x by the padding.
            textView.textContainer?.lineFragmentPadding = 0

            scrollView.documentView = textView
            scrollView.scrollerStyle = .overlay
            scrollView.hasHorizontalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.findBarPosition = .belowContent
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidResize), name: NSView.frameDidChangeNotification, object: scrollView.contentView)

            gutter.textView = textView
            gutter.clipsToBounds = true
            gutter.setContentHuggingPriority(.required, for: .horizontal)
            gutter.setContentCompressionResistancePriority(.required, for: .horizontal)
            textView.gutter = gutter
            gutter.onSelect = { [weak self] textView, lines in self?.comment(on: textView, lines: lines) }
            return [gutter, scrollView]
        }

        func update(_ view: ReviewDiffViews) {
            let isSplitChanged = view.isUnified != parent?.isUnified || view.splitRatio != parent?.splitRatio
            parent = view
            if isSplitChanged {
                if view.isUnified { leftPane.removeFromSuperview() } else if leftPane.superview == nil { split.addSubview(leftPane, positioned: .below, relativeTo: nil) }
                split.resizeSubviews(withOldSize: split.frame.size)
            }
            minimap.isHidden = !view.showsMinimap
            right.isEditable = !view.isModifiedAbsent && view.editor != nil
            left.isAbsent = view.isOriginalAbsent
            right.isAbsent = view.isModifiedAbsent

            let isStyleChanged = view.style != left.style
            let isOriginalChanged = view.original != loadedOriginal
            let isModifiedChanged = view.modified != loadedModified
            let isModeChanged = view.isUnified != (right.unifiedOriginal != nil)
            if isOriginalChanged {
                loadedOriginal = view.original
                left.string = view.original
                left.side = nil
                left.syntaxRuns = []
                applied = nil
            }
            if isOriginalChanged || isModifiedChanged { closePeek() }
            if isModifiedChanged {
                loadedModified = view.modified
                right.string = view.modified
                right.side = nil
                right.syntaxRuns = []
                right.history.removeAllActions()
                applied = nil
            }

            let clip = right.enclosingScrollView?.contentView.bounds.minY ?? 0
            let anchor = isModeChanged ? right.line(atY: clip).flatMap { line in right.side.flatMap { $0.rows.indices.contains(line) ? (line: line, offset: clip - right.top(ofRow: $0.rows[line])) : nil } } : nil
            right.unifiedOriginal = view.isUnified ? left : nil
            let analysis = view.analysis.flatMap { $0.id != applied?.id && $0.original == loadedOriginal && $0.modified == loadedModified ? $0 : nil }
            if let analysis {
                applied = analysis
                left.syntaxRuns = analysis.originalRuns
                right.syntaxRuns = analysis.modifiedRuns
            }
            if let applied, analysis != nil || isModeChanged {
                left.side = view.isUnified ? applied.diff.unifiedOriginal : applied.diff.original
                right.side = view.isUnified ? applied.diff.unifiedModified : applied.diff.modified
            }
            if isStyleChanged {
                left.style = view.style
                right.style = view.style
                for inline in Array(cards.values) + [draft?.view].compactMap(\.self) { inline.apply(view.style) }
                for card in threadCards.values { card.apply(view.style) }
            }
            if isStyleChanged || isOriginalChanged || isModifiedChanged || isModeChanged || analysis != nil {
                reload()
            }
            layoutInline()
            if let anchor, let rows = right.side?.rows, rows.indices.contains(anchor.line) {
                right.scrollVertically(to: right.top(ofRow: rows[anchor.line]) + anchor.offset)
            }

            right.diagnostics = view.diagnostics
            if view.takesFocus { right.focusesInWindow = true }
            for textView in [left, right] {
                textView.onHover = view.language == nil ? nil : { [weak self, weak textView] offset in
                    guard let textView else { return nil }

                    return await self?.hover(in: textView, at: offset)
                }
                textView.onDefinition = view.language == nil ? nil : { [weak self, weak textView] offset in
                    if let textView { self?.definition(in: textView, at: offset) }
                }
                textView.onReferences = view.language == nil ? nil : { [weak self, weak textView] offset in
                    if let textView { self?.references(in: textView, at: offset) }
                }
            }
            if let reveal = view.reveal, applied?.modified == loadedModified {
                right.reveal(NSRange(location: right.offset(of: reveal.start), length: max(right.offset(of: reveal.end) - right.offset(of: reveal.start), 0)))
                Task { view.onRevealed() }
            }
            if let reveal = view.revealLine, applied != nil {
                let numbered = reveal.side == .original ? left : right
                let owner = view.isUnified ? right : numbered
                if reveal.line > 0, !numbered.isAbsent, let rows = numbered.side?.rows, rows.indices.contains(reveal.line - 1) {
                    owner.scrollVertically(to: owner.top(ofRow: rows[reveal.line - 1]) - owner.rowHeight)
                }
                Task { view.onLineRevealed() }
            }
            if let step = view.changeStep, applied != nil {
                right.goToChange(by: step)
                Task { view.onChangeStepped() }
            }
            if let id = view.editsComment, applied != nil, let card = cards[id] {
                if !card.isHidden { edit(id) }
                Task { view.onEditing() }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ReviewTextView, textView === right else { return }

            loadedModified = textView.string
            closePeek()
            parent?.onEdit(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? ReviewTextView)?.gutter?.needsDisplay = true
            (notification.object as? ReviewTextView)?.highlightOccurrences { [weak self] in
                self?.ruler.needsDisplay = true
                self?.minimap.needsDisplay = true
            }
        }

        func undoManager(for _: NSTextView) -> UndoManager? {
            right.history
        }

        @objc private func clipViewDidScroll(_ notification: Notification) {
            left.dismissHover()
            right.dismissHover()
            left.gutter?.needsDisplay = true
            right.gutter?.needsDisplay = true
            minimap.needsDisplay = true
            ruler.needsDisplay = true
            layoutInline()
            guard let source = notification.object as? NSClipView, let target = [left, right].compactMap(\.enclosingScrollView).first(where: { $0.contentView !== source }), target.contentView.bounds.minY != source.bounds.minY else { return }

            target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: source.bounds.minY))
            target.reflectScrolledClipView(target.contentView)
        }

        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize _: NSSize) {
            let available = splitView.bounds.width - splitView.dividerThickness
            guard splitView.subviews.count == 2, available > 0 else { return splitView.adjustSubviews() }

            let minimum = min(200, available / 2)
            let position = min(max((parent?.splitRatio ?? 0.5) * available, minimum), available - minimum).rounded()
            let height = splitView.bounds.height
            splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: position, height: height)
            splitView.subviews[1].frame = NSRect(x: position + splitView.dividerThickness, y: 0, width: available - position, height: height)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt _: Int) -> CGFloat {
            max(proposedMinimumPosition, min(200, (splitView.bounds.width - splitView.dividerThickness) / 2))
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt _: Int) -> CGFloat {
            let available = splitView.bounds.width - splitView.dividerThickness
            return min(proposedMaximumPosition, available - min(200, available / 2))
        }

        @objc private func clipViewDidResize(_: Notification) {
            minimap.needsDisplay = true
            ruler.needsDisplay = true
            layoutInline()
        }

        private func reload() {
            left.refresh()
            right.refresh()
            right.minimumWidth = right.unifiedOriginal == nil ? 0 : (left.textLayoutManager?.usageBoundsForTextContainer.width ?? 0) + 2 * left.textContainerInset.width
            right.setFrameSize(NSSize(width: (right.textLayoutManager?.usageBoundsForTextContainer.width ?? 0) + 2 * right.textContainerInset.width, height: right.frame.height))
            right.needsDisplay = true
            right.gutter?.needsDisplay = true
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

            let comments = parent.comments.filter { $0.path == parent.path && $0.compare == parent.compare }
            for (id, card) in cards where !comments.contains(where: { $0.id == id }) {
                card.removeFromSuperview()
                cards[id] = nil
                if draft?.editing == id {
                    draft?.view.removeFromSuperview()
                    draft = nil
                }
            }
            let isUnified = right.unifiedOriginal != nil
            var placed: [(view: NSView, owner: ReviewTextView, row: Int)] = []
            for comment in comments {
                let numbered = comment.side == .original ? left : right
                let owner = isUnified ? right : numbered
                let numbers = comment.endLine > comment.line ? "Lines \(comment.line)–\(comment.endLine)" : "Line \(comment.line)"
                let card = cards[comment.id] ?? ReviewInlineComment(title: comment.side == .original ? "Removed \(numbers)" : numbers, text: comment.text, kind: .card(
                    onEdit: { [weak self] in self?.edit(comment.id) },
                    onDelete: { [weak self] in self?.parent?.comments.removeAll { $0.id == comment.id } }
                ), style: owner.style)
                cards[comment.id] = card
                if card.field.string != comment.text { card.field.string = comment.text }
                card.onSendToPullRequest = parent.isWritingPullRequest ? nil : parent.onSendComment.map { send in { send(comment) } }
                let view = draft.flatMap { $0.editing == comment.id ? $0.view : nil } ?? card
                card.isHidden = view !== card
                if view.superview !== owner { owner.addSubview(view) }
                let rows = numbered.side?.rows ?? []
                view.isHidden = !rows.indices.contains(comment.endLine - 1)
                if !view.isHidden { placed.append((view, owner, rows[comment.endLine - 1])) }
            }
            let threadIDs = Set(parent.threads.map(\.id))
            for (id, card) in threadCards where !threadIDs.contains(id) {
                card.removeFromSuperview()
                threadCards[id] = nil
            }
            for thread in parent.threads {
                let numbered = thread.side == .original ? left : right
                let owner = isUnified ? right : numbered
                let previous = threadCards[thread.id]
                guard let line = thread.line, line > 0, !numbered.isAbsent, let rows = numbered.side?.rows, rows.indices.contains(line - 1) else {
                    previous?.removeFromSuperview()
                    continue
                }

                let card: ReviewThreadCard
                if let previous, previous.thread == thread {
                    card = previous
                } else {
                    previous?.removeFromSuperview()
                    card = ReviewThreadCard(thread: thread, style: owner.style, isExpanded: previous.flatMap { $0.thread.isResolved == thread.isResolved ? $0.isExpanded : nil }, onReply: { [weak self] in
                        self?.reply(to: thread)
                    }, onSend: { [weak self] in self?.parent?.onSendThread(thread) }, onResize: { [weak self] in self?.layoutInline() })
                    threadCards[thread.id] = card
                }
                card.replyButton.isEnabled = !parent.isWritingPullRequest
                if card.superview !== owner { owner.addSubview(card) }
                placed.append((card, owner, rows[line - 1]))
                if card.isExpanded, let draft, draft.replyingTo == thread.id {
                    if draft.view.superview !== owner { owner.addSubview(draft.view) }
                    draft.view.isHidden = false
                    placed.append((draft.view, owner, rows[line - 1]))
                }
            }
            if let draft, draft.replyingTo != nil, !placed.contains(where: { $0.view === draft.view }) { draft.view.isHidden = true }
            if let draft, draft.editing == nil, draft.replyingTo == nil, let rows = draft.numbered.side?.rows, rows.indices.contains(draft.line) {
                let owner = isUnified ? right : draft.numbered
                if draft.view.superview !== owner { owner.addSubview(draft.view) }
                placed.append((draft.view, owner, rows[draft.line]))
            }
            if let peek, let rows = peek.numbered.side?.rows, rows.indices.contains(peek.line) {
                let owner = isUnified ? right : peek.numbered
                if peek.view.superview !== owner { owner.addSubview(peek.view) }
                placed.append((peek.view, owner, rows[peek.line]))
            }

            let inset: CGFloat = 6
            let indent = right.textContainerInset.width
            let widths = placed.map { max(($0.owner.enclosingScrollView?.contentView.bounds.width ?? 0) - indent - 2 * inset, 120) }
            let heights = zip(placed, widths).map { item, width in
                if let card = item.view as? ReviewInlineComment { return card.fittingHeight(forWidth: width) }
                if let card = item.view as? ReviewThreadCard { return card.fittingHeight(forWidth: width) }
                return width < ReviewReferencesPeek.stackedBelowWidth ? ReviewReferencesPeek.stackedHeight : ReviewReferencesPeek.height
            }
            var reserved: [Int: CGFloat] = [:]
            for (item, height) in zip(placed, heights) { reserved[item.row, default: 0] += height + inset * 2 }
            reserved = reserved.mapValues { $0.rounded(.up) }
            if reserved != right.reserved {
                left.reserved = reserved
                right.reserved = reserved
                documentsDidResize()
            }

            var stacked: [Int: CGFloat] = [:]
            for ((item, height), width) in zip(zip(placed, heights), widths) {
                let top = item.owner.top(ofRow: item.row + 1) - reserved[item.row, default: 0] + stacked[item.row, default: 0] + inset
                stacked[item.row, default: 0] += height + inset * 2
                item.view.frame = NSRect(x: item.owner.visibleRect.minX + indent, y: top, width: width, height: height)
            }
        }

        private func comment(on textView: ReviewTextView, lines: ClosedRange<Int>) {
            guard let rows = textView.side?.rows, rows.indices.contains(lines.upperBound) else { return }

            let isRemoval = textView === left && lines.contains { left.side?.changedLines.contains($0) == true }
            let numbered = textView === left && !isRemoval ? right : textView
            let owner = right.unifiedOriginal != nil ? right : numbered
            let numberedRows = numbered.side?.rows ?? []
            let first = numbered === textView ? lines.lowerBound : numberedRows.partitioningIndex { $0 >= rows[lines.lowerBound] }
            let last = numbered === textView ? lines.upperBound : numberedRows.partitioningIndex { $0 >= rows[lines.upperBound] }
            let source = (isRemoval ? loadedOriginal : loadedModified) ?? ""
            let texts = source.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(first).prefix(last - first + 1)
            let snippet = texts.map { isRemoval ? "-\($0)" : String($0) }.joined(separator: "\n")
            let numbers = last > first ? "Lines \(first + 1)–\(last + 1)" : "Line \(first + 1)"
            let path = parent?.path ?? ""
            let compare = parent.flatMap(\.compare)

            let other = textView === left ? right : left
            draft?.view.removeFromSuperview()
            other.selectedLines = nil
            other.needsDisplay = true
            let view = ReviewInlineComment(title: isRemoval ? "Removed \(numbers)" : numbers, text: "", kind: .draft(
                onAdd: { [weak self] text in
                    guard !text.isEmpty else { return }

                    self?.parent?.comments.append(ReviewComment(id: UUID().uuidString, path: path, line: first + 1, endLine: last + 1, text: text, snippet: snippet, side: isRemoval ? .original : .modified, compare: compare))
                    self?.closeDraft()
                },
                onCancel: { [weak self] in self?.closeDraft() },
                onResize: { [weak self] in self?.layoutInline() }
            ), style: owner.style)
            draft = (view, numbered, last, nil, nil)
            layoutInline()
            owner.window?.makeFirstResponder(view.field)
            owner.scrollToVisible(NSRect(x: owner.visibleRect.minX, y: view.frame.minY, width: 1, height: view.frame.height))
        }

        private func edit(_ id: String) {
            guard let comment = parent?.comments.first(where: { $0.id == id }), let card = cards[id] else { return }

            closeDraft()
            let numbered = comment.side == .original ? left : right
            let owner = right.unifiedOriginal != nil ? right : numbered
            let view = ReviewInlineComment(title: card.header.stringValue, text: comment.text, kind: .draft(
                onAdd: { [weak self] text in
                    if !text.isEmpty, let index = self?.parent?.comments.firstIndex(where: { $0.id == id }) { self?.parent?.comments[index].text = text }
                    self?.closeDraft()
                },
                onCancel: { [weak self] in self?.closeDraft() },
                onResize: { [weak self] in self?.layoutInline() }
            ), style: owner.style)
            draft = (view, numbered, comment.endLine - 1, id, nil)
            layoutInline()
            owner.window?.makeFirstResponder(view.field)
            owner.scrollToVisible(NSRect(x: owner.visibleRect.minX, y: view.frame.minY, width: 1, height: view.frame.height))
        }

        private func reply(to thread: ReviewThread) {
            guard let parent, let line = thread.line, let owner = threadCards[thread.id]?.superview as? ReviewTextView else { return }

            if draft?.replyingTo == thread.id, let view = draft?.view {
                owner.window?.makeFirstResponder(view.field)
                return
            }

            closeDraft()
            let view = ReviewInlineComment(title: "Reply to Review Thread", text: parent.replyDrafts[thread.id] ?? "", kind: .draft(
                onAdd: { [weak self] text in
                    guard !text.isEmpty, let parent = self?.parent, !parent.isWritingPullRequest, let composer = self?.draft?.view else { return }

                    composer.isSubmitting = true
                    Task { [weak self] in
                        let sent = await parent.onReply(thread.id, text)
                        composer.isSubmitting = false
                        if sent, self?.draft?.view === composer { self?.closeDraft() }
                    }
                },
                onCancel: { [weak self] in
                    self?.parent?.replyDrafts[thread.id] = nil
                    self?.closeDraft()
                },
                onResize: { [weak self] in
                    guard let self, let draft, draft.replyingTo == thread.id else { return }

                    self.parent?.replyDrafts[thread.id] = draft.view.field.string
                    layoutInline()
                }
            ), style: owner.style, submitTitle: "Send Reply")
            draft = (view, thread.side == .original ? left : right, line - 1, nil, thread.id)
            layoutInline()
            owner.window?.makeFirstResponder(view.field)
            owner.scrollToVisible(NSRect(x: owner.visibleRect.minX, y: view.frame.minY, width: 1, height: view.frame.height))
        }

        private func closeDraft() {
            guard let draft else { return }

            if let window = draft.view.window, window.firstResponder === draft.view.field { window.makeFirstResponder(draft.view.superview) }
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

final class ReviewSplitView: NSSplitView {
    var onDrag: (Double) -> Void = { _ in }
    var resetRatio = 0.5

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, hitTest(superview?.convert(event.locationInWindow, from: nil) ?? .zero) === self {
            onDrag(resetRatio)
            return
        }

        let frame = subviews[0].frame
        super.mouseDown(with: event)
        guard subviews[0].frame != frame else { return }

        onDrag(isVertical ? subviews[0].frame.width / (bounds.width - dividerThickness) : subviews[0].frame.height / (bounds.height - dividerThickness))
    }
}

extension ReviewDiffViews.Coordinator {
    private struct Question {
        let language: ReviewLanguage
        let path: String
        let working: String
        let base: ReviewLanguageBase?
        let position: LanguageServerPosition
        let diff: ReviewDiff?
    }

    private func question(_ textView: ReviewTextView, at offset: Int) async -> Question? {
        guard let parent, let language = parent.language, let working = parent.editor == nil && parent.compare == .committed ? parent.workingText() : right.string else { return nil }

        let source = textView.string
        let position = textView.position(ofOffset: offset)
        guard source != working else { return Question(language: language, path: parent.path, working: working, base: nil, position: position, diff: nil) }

        let diff = await Task.detached { ReviewDiff(original: source, modified: working) }.value
        let line = workingLine(of: position.line, in: diff)
        return Question(language: language, path: parent.path, working: working, base: line == nil ? language.base(of: parent.path, text: source) : nil, position: LanguageServerPosition(line: line ?? position.line, character: position.character), diff: diff)
    }

    private func workingLine(of line: Int, in diff: ReviewDiff) -> Int? {
        guard diff.original.rows.indices.contains(line), !diff.original.changedLines.contains(line) else { return nil }

        let row = diff.original.rows[line]
        let mapped = diff.modified.rows.partitioningIndex { $0 >= row }
        return diff.modified.rows.indices.contains(mapped) && diff.modified.rows[mapped] == row ? mapped : nil
    }

    private func landing(of location: LanguageServerLocation, for question: Question) -> (location: LanguageServerLocation, isBase: Bool) {
        guard let base = question.base, location.url.lastPathComponent == base.url.lastPathComponent else { return (location, false) }
        guard let diff = question.diff, let line = workingLine(of: location.range.start.line, in: diff) else { return (location, true) }

        let range = LanguageServerRange(start: LanguageServerPosition(line: line, character: location.range.start.character), end: LanguageServerPosition(line: location.range.end.line - location.range.start.line + line, character: location.range.end.character))
        return (LanguageServerLocation(url: URL(filePath: question.language.root).appending(path: question.path), range: range), false)
    }

    func hover(in textView: ReviewTextView, at offset: Int) async -> String? {
        guard let question = await question(textView, at: offset) else { return nil }

        return await question.language.hover(question.path, text: question.working, base: question.base, at: question.position)
    }

    func definition(in textView: ReviewTextView, at offset: Int) {
        Task {
            guard let question = await question(textView, at: offset), let location = await question.language.definition(question.path, text: question.working, base: question.base, at: question.position) else { return }

            let asked = question.base?.url ?? URL(filePath: question.language.root).appending(path: question.path)
            let range = location.range
            if location.url.resolvingSymlinksInPath().path == asked.resolvingSymlinksInPath().path, range.start.line == question.position.line, (range.start.character...max(range.end.character, range.start.character)).contains(question.position.character) {
                return await showReferences(question, in: textView, at: offset)
            }
            let landing = landing(of: location, for: question)
            if landing.isBase { return revealBase(landing.location.range, in: textView) }
            let selection = textView === right ? NSRange(location: offset, length: 0) : right.selectedRange()
            let origin = LanguageServerRange(start: right.position(ofOffset: selection.location), end: right.position(ofOffset: NSMaxRange(selection)))
            parent?.onDefinition(landing.location, origin)
        }
    }

    func references(in textView: ReviewTextView, at offset: Int) {
        Task {
            guard let question = await question(textView, at: offset) else { return }

            await showReferences(question, in: textView, at: offset)
        }
    }

    private func showReferences(_ question: Question, in textView: ReviewTextView, at offset: Int) async {
        guard let locations = await question.language.references(question.path, text: question.working, base: question.base, at: question.position) else { return }

        let selection = textView === right ? NSRange(location: offset, length: 0) : right.selectedRange()
        let origin = LanguageServerRange(start: right.position(ofOffset: selection.location), end: right.position(ofOffset: NSMaxRange(selection)))
        let root = URL(filePath: question.language.root).resolvingSymlinksInPath().path + "/"
        var texts = [question.path: question.working]
        var references: [ReviewReference] = []
        for location in locations {
            let landing = landing(of: location, for: question)
            if landing.isBase {
                references.append(ReviewReference(path: question.path, location: landing.location, text: question.base?.text ?? "", isBase: true))
                continue
            }
            guard !location.url.lastPathComponent.hasPrefix(".berth-") else { continue }

            let file = landing.location.url.resolvingSymlinksInPath().path
            let path = file.hasPrefix(root) ? String(file.dropFirst(root.count)) : file
            texts[path] = texts[path] ?? (try? String(contentsOfFile: file, encoding: .utf8))
            references.append(ReviewReference(path: path, location: landing.location, text: texts[path] ?? "", isBase: false))
        }

        closePeek()
        let view = ReviewReferencesPeek(references: references, current: question.path, style: right.style, onOpen: { [weak self, weak textView] reference in
            self?.closePeek()
            if reference.isBase {
                textView.map { self?.revealBase(reference.location.range, in: $0) }
            } else {
                self?.parent?.onDefinition(reference.location, origin)
            }
        }, onClose: { [weak self] in self?.closePeek() })
        peek = (view, textView, textView.position(ofOffset: offset).line)
        layoutInline()
        let owner = right.unifiedOriginal != nil ? right : textView
        owner.scrollToVisible(NSRect(x: owner.visibleRect.minX, y: view.frame.minY - owner.rowHeight, width: 1, height: view.frame.height + owner.rowHeight * 2))
        owner.window?.makeFirstResponder(view.list)
    }

    private func revealBase(_ range: LanguageServerRange, in textView: ReviewTextView) {
        guard right.unifiedOriginal === textView, let rows = textView.side?.rows, rows.indices.contains(range.start.line) else {
            return textView.reveal(NSRange(location: textView.offset(of: range.start), length: max(textView.offset(of: range.end) - textView.offset(of: range.start), 0)))
        }

        right.scrollVertically(to: right.top(ofRow: rows[range.start.line]) - right.visibleRect.height / 3)
    }

    func closePeek() {
        guard let peek else { return }

        if let window = peek.view.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: peek.view) { window.makeFirstResponder(peek.view.superview) }
        peek.view.removeFromSuperview()
        self.peek = nil
        layoutInline()
    }
}

private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}
