import BerthCore
import SwiftUI

struct ReviewDiffPane: View {
    let path: String
    let compare: ReviewCompare?
    let contents: ReviewContents
    let editor: ReviewTextView?
    @Binding var draft: String?
    @Binding var comments: [ReviewComment]
    let style: ReviewStyle
    let language: ReviewLanguage?
    let reveal: LanguageServerRange?
    let isUnified: Bool
    let takesFocus: Bool
    let onRevealed: () -> Void
    let onDefinition: (LanguageServerLocation) -> Void
    @AppStorage(ReviewStyle.showsMinimapKey) private var showsMinimap = true
    @AppStorage(LanguageServerEntry.storageKey) private var configuredServers = ""
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
                language: contents.modified == nil ? nil : language,
                diagnostics: contents.modified == nil ? [] : language?.diagnostics(for: path) ?? [],
                reveal: reveal,
                isUnified: isUnified,
                takesFocus: takesFocus,
                onRevealed: onRevealed,
                onDefinition: onDefinition,
                onEdit: { draft = $0 == loaded ? nil : $0 }
            )
            .task(id: [original, modified, configuredServers]) {
                if analysis != nil { try? await Task.sleep(for: .milliseconds(300)) }
                guard !Task.isCancelled else { return }

                let base = compare == nil ? modified : original
                let computed = await Task.detached { ReviewDiffAnalysis(original: original, modified: modified, base: base, path: path) }.value
                guard !Task.isCancelled else { return }
                analysis = computed
                if contents.modified != nil { await language?.sync(path, text: modified) }
            }
            .onChange(of: language == nil) {
                Task { if contents.modified != nil { await language?.sync(path, text: modified) } }
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

    init(original: String, modified: String, base: String, path: String) {
        self.original = original
        self.modified = modified
        diff = ReviewDiff(original: base, modified: modified)
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
    let language: ReviewLanguage?
    let diagnostics: [LanguageServerDiagnostic]
    let reveal: LanguageServerRange?
    let isUnified: Bool
    let takesFocus: Bool
    let onRevealed: () -> Void
    let onDefinition: (LanguageServerLocation) -> Void
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(right: editor ?? ReviewTextView(usingTextLayoutManager: true))
    }

    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        let stack = NSStackView(views: coordinator.makeSide(coordinator.left) + coordinator.makeSide(coordinator.right) + [coordinator.minimap, coordinator.ruler])
        stack.spacing = 0
        coordinator.equalWidths = stack.views[1].widthAnchor.constraint(equalTo: stack.views[3].widthAnchor)
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
        if isUnified { context.coordinator.equalWidths?.isActive = false }
        stack.views[0].isHidden = isUnified
        stack.views[1].isHidden = isUnified
        if !isUnified { context.coordinator.equalWidths?.isActive = true }
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ stack: NSStackView, coordinator: Coordinator) {
        (Array(coordinator.cards.values) + [coordinator.draft?.view].compactMap(\.self)).forEach { $0.removeFromSuperview() }
        guard coordinator.right.delegate === coordinator else { return }
        coordinator.right.selectedLines = nil
        coordinator.right.unifiedOriginal = nil
        coordinator.right.minimumWidth = 0
        coordinator.right.reserved = [:]
        coordinator.right.dismissHover()
        coordinator.right.onHover = nil
        coordinator.right.onDefinition = nil
        coordinator.right.focusesInWindow = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let left = ReviewTextView(usingTextLayoutManager: true)
        let right: ReviewTextView
        let minimap = ReviewMinimap()
        let ruler = ReviewOverviewRuler()
        var equalWidths: NSLayoutConstraint?
        private var parent: ReviewDiffViews?
        private var loadedOriginal: String?
        private var loadedModified: String?
        private var applied: ReviewDiffAnalysis?
        var cards: [String: ReviewInlineComment] = [:]
        var draft: (view: ReviewInlineComment, numbered: ReviewTextView, line: Int)?

        init(right: ReviewTextView) {
            self.right = right
            loadedModified = right.string
        }

        func makeSide(_ textView: ReviewTextView) -> [NSView] {
            let scrollView = OverlayScrollView()
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
            gutter.drawsSeparator = textView === right
            gutter.setContentHuggingPriority(.required, for: .horizontal)
            gutter.setContentCompressionResistancePriority(.required, for: .horizontal)
            textView.gutter = gutter
            gutter.onSelect = { [weak self] textView, lines in self?.comment(on: textView, lines: lines) }
            return [gutter, scrollView]
        }

        func update(_ view: ReviewDiffViews) {
            parent = view
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
            right.onHover = view.language == nil ? nil : { [weak self] offset in await self?.hover(at: offset) }
            right.onDefinition = view.language == nil ? nil : { [weak self] offset in self?.definition(at: offset) }
            if let reveal = view.reveal, applied?.modified == loadedModified {
                right.reveal(NSRange(location: right.offset(of: reveal.start), length: max(right.offset(of: reveal.end) - right.offset(of: reveal.start), 0)))
                Task { view.onRevealed() }
            }
        }

        private func hover(at offset: Int) async -> String? {
            guard let parent, let language = parent.language else { return nil }
            return await language.hover(parent.path, text: right.string, at: right.position(ofOffset: offset))
        }

        private func definition(at offset: Int) {
            guard let parent, let language = parent.language else { return }

            let text = right.string
            let position = right.position(ofOffset: offset)
            Task {
                guard let location = await language.definition(parent.path, text: text, at: position) else { return }
                parent.onDefinition(location)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ReviewTextView, textView === right else { return }
            loadedModified = textView.string
            parent?.onEdit(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? ReviewTextView)?.gutter?.needsDisplay = true
            (notification.object as? ReviewTextView)?.highlightOccurrences { [weak self] in
                self?.ruler.needsDisplay = true
                self?.minimap.needsDisplay = true
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            right.history
        }

        @objc private func clipViewDidScroll(_ notification: Notification) {
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

        @objc private func clipViewDidResize(_ notification: Notification) {
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
            }
            let isUnified = right.unifiedOriginal != nil
            var placed: [(view: ReviewInlineComment, owner: ReviewTextView, row: Int)] = []
            for comment in comments {
                let numbered = comment.side == .original ? left : right
                let owner = isUnified ? right : numbered
                let numbers = comment.endLine > comment.line ? "Lines \(comment.line)–\(comment.endLine)" : "Line \(comment.line)"
                let card = cards[comment.id] ?? ReviewInlineComment(title: comment.side == .original ? "Removed \(numbers)" : numbers, text: comment.text, kind: .card(onDelete: { [weak self] in self?.parent?.comments.removeAll { $0.id == comment.id } }), style: owner.style)
                cards[comment.id] = card
                if card.superview !== owner { owner.addSubview(card) }
                let rows = numbered.side?.rows ?? []
                card.isHidden = !rows.indices.contains(comment.endLine - 1)
                if !card.isHidden { placed.append((card, owner, rows[comment.endLine - 1])) }
            }
            if let draft, let rows = draft.numbered.side?.rows, rows.indices.contains(draft.line) {
                let owner = isUnified ? right : draft.numbered
                if draft.view.superview !== owner { owner.addSubview(draft.view) }
                placed.append((draft.view, owner, rows[draft.line]))
            }

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
                    self?.parent?.comments.append(ReviewComment(id: UUID().uuidString, path: path, line: first + 1, endLine: last + 1, text: text, snippet: snippet, side: isRemoval ? .original : .modified, compare: compare))
                    self?.closeDraft()
                },
                onCancel: { [weak self] in self?.closeDraft() },
                onResize: { [weak self] in self?.layoutInline() }
            ), style: owner.style)
            draft = (view, numbered, last)
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

private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}
