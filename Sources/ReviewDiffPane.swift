import BerthCore
import SwiftUI

struct ReviewDiffPane: View {
    let path: String
    let contents: ReviewContents
    @Binding var draft: String?
    let onComment: (_ line: Int, _ endLine: Int, _ text: String, _ snippet: String) -> Void
    @Environment(\.ghosttyTheme) private var theme
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
                original: original,
                modified: modified,
                isOriginalAbsent: contents.original == nil,
                isModifiedAbsent: contents.modified == nil,
                analysis: analysis,
                theme: theme,
                onEdit: { draft = $0 == loaded ? nil : $0 },
                onComment: onComment
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
    let original: String
    let modified: String
    let isOriginalAbsent: Bool
    let isModifiedAbsent: Bool
    let analysis: ReviewDiffAnalysis?
    let theme: GhosttyTheme
    let onEdit: (String) -> Void
    let onComment: (_ line: Int, _ endLine: Int, _ text: String, _ snippet: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        let stack = NSStackView(views: coordinator.makeSide(coordinator.left) + coordinator.makeSide(coordinator.right))
        stack.spacing = 0
        stack.views[1].widthAnchor.constraint(equalTo: stack.views[3].widthAnchor).isActive = true
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSPopoverDelegate {
        let left = ReviewTextView(usingTextLayoutManager: true)
        let right = ReviewTextView(usingTextLayoutManager: true)
        private let undoManager = UndoManager()
        private var parent: ReviewDiffViews?
        private var loadedOriginal: String?
        private var loadedModified: String?
        private var applied: ReviewDiffAnalysis?
        private var popover: NSPopover?

        func makeSide(_ textView: ReviewTextView) -> [NSView] {
            let scrollView = NSScrollView()
            let gutter = ReviewGutter()
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

            gutter.textView = textView
            gutter.drawsSeparator = textView === right
            gutter.setContentHuggingPriority(.required, for: .horizontal)
            gutter.setContentCompressionResistancePriority(.required, for: .horizontal)
            textView.gutter = gutter
            gutter.onSelect = { [weak self, weak textView, weak gutter] lines, rect in
                guard let self, let textView, let gutter else { return }
                comment(on: textView, lines: lines, at: rect, in: gutter)
            }
            return [gutter, scrollView]
        }

        func update(_ view: ReviewDiffViews) {
            parent = view
            right.isEditable = !view.isModifiedAbsent
            left.isAbsent = view.isOriginalAbsent
            right.isAbsent = view.isModifiedAbsent

            let isThemeChanged = view.theme != left.theme
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
            guard isThemeChanged || isOriginalChanged || isModifiedChanged || analysis != nil else { return }

            left.tint = view.theme.closed
            right.tint = view.theme.working
            for textView in [left, right] {
                textView.theme = view.theme
                textView.refresh()
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ReviewTextView, textView === right else { return }
            loadedModified = textView.string
            parent?.onEdit(textView.string)
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        @objc private func clipViewDidScroll(_ notification: Notification) {
            left.gutter?.needsDisplay = true
            right.gutter?.needsDisplay = true
            guard let source = notification.object as? NSClipView, let target = [left, right].compactMap(\.enclosingScrollView).first(where: { $0.contentView !== source }), target.contentView.bounds.minY != source.bounds.minY else { return }

            target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: source.bounds.minY))
            target.reflectScrolledClipView(target.contentView)
        }

        private func comment(on textView: ReviewTextView, lines: ClosedRange<Int>, at rect: NSRect, in gutter: ReviewGutter) {
            let isRemoval = textView === left && lines.contains { left.side?.changedLines.contains($0) == true }
            let hunks = applied?.diff.hunks ?? []
            let delta = { (line: Int) in hunks.filter { $0.originalLines.upperBound <= line }.reduce(0) { $0 + $1.modifiedLines.count - $1.originalLines.count } }
            let usesOwnNumbers = textView === right || isRemoval
            let first = usesOwnNumbers ? lines.lowerBound : lines.lowerBound + delta(lines.lowerBound)
            let last = usesOwnNumbers ? lines.upperBound : lines.upperBound + delta(lines.upperBound)
            let source = (isRemoval ? loadedOriginal : loadedModified) ?? ""
            let texts = source.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(first).prefix(last - first + 1)
            let snippet = texts.map { isRemoval ? "-\($0)" : String($0) }.joined(separator: "\n")
            let numbers = last > first ? "Lines \(first + 1)–\(last + 1)" : "Line \(first + 1)"

            let popover = NSPopover()
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: ReviewCommentField(title: isRemoval ? "Removed \(numbers)" : numbers) { [weak self] text in
                self?.parent?.onComment(first + 1, last + 1, text, snippet)
                self?.popover?.close()
            })
            self.popover = popover
            popover.show(relativeTo: rect, of: gutter, preferredEdge: .maxX)
        }

        func popoverDidClose(_ notification: Notification) {
            for gutter in [left.gutter, right.gutter].compactMap(\.self) {
                gutter.selection = nil
                gutter.needsDisplay = true
            }
            popover = nil
        }
    }
}

private struct ReviewCommentField: View {
    let title: String
    let onSubmit: (String) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            TextField("Comment", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Comment", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }

    private func submit() {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty else { return }
        onSubmit(comment)
    }
}
