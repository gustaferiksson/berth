import AppKit
import BerthCore

extension ReviewTextView {
    struct CaretState {
        var ranges = [NSRange(location: 0, length: 0)]
        var primary = 0
        var isMirroring = false
        var isFanningOut = false
        var headsAtStart = false
        var history: [[NSRange]] = []
        var column: (anchor: Int, focus: Int)?
        var goalX: CGFloat?
        var findSession: (needle: String, matching: ReviewCarets.Matching, carets: [NSRange])?
        var blink: Timer?
        var isBlinkOn = true
    }

    func performCaretAction(_ action: CaretAction) {
        guard isEditable else { return }

        if action == .addCursorAbove || action == .addCursorBelow { return addCursor(lineOffset: action == .addCursorAbove ? -1 : 1) }
        if action == .addNextOccurrence { return addNextOccurrence() }
        if action == .moveLastSelectionToNextOccurrence { return moveLastSelectionToNextOccurrence() }
        if action == .selectAllOccurrences || action == .changeAllOccurrences { return selectAllOccurrences() }
        if action == .addCursorsToLineEnds { return addCursorsToLineEnds() }
        if action == .undoCursor, let previous = carets.history.popLast() {
            let history = carets.history
            applyCarets(previous, primaryAt: previous.last?.location)
            carets.history = history
            return
        }
        if action == .collapseCursors { applyCarets([carets.ranges[carets.primary]], primaryAt: nil) }
    }

    func caretMouseDown(_ event: NSEvent) -> Bool {
        carets.column = nil
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard isEditable, flags == .option || flags == [.option, .shift] else { return false }

        let point = convert(event.locationInWindow, from: nil)
        guard let line = line(atY: point.y), let row = segments(of: NSRange(location: lineStarts[line], length: 0)).first?.rect, point.y >= row.minY, point.y < row.minY + rowHeight + (side.flatMap { $0.rows.indices.contains(line) ? alignedExtras[$0.rows[line]] : nil } ?? 0) else { return true }

        window?.makeFirstResponder(self)
        let index = characterIndexForInsertion(at: NSPoint(x: point.x, y: wrapsLines ? point.y : row.midY))
        guard flags == .option else {
            columnSelect(anchor: index, focus: index)
            return true
        }

        let existing = carets.ranges.firstIndex { $0.length == 0 && $0.location == index }
        guard let existing, carets.ranges.count > 1 else {
            applyCarets(carets.ranges + [NSRange(location: index, length: 0)], primaryAt: index)
            return true
        }

        let remaining = carets.ranges.enumerated().filter { $0.offset != existing }.map(\.element)
        applyCarets(remaining, primaryAt: remaining.last?.location)
        return true
    }

    func drawCarets(in rect: NSRect) {
        guard carets.ranges.count > 1 else { return }

        let isFocused = window?.firstResponder === self && window?.isKeyWindow == true
        for (index, caret) in carets.ranges.enumerated() where index != carets.primary && (caret.length > 0 || isFocused && carets.isBlinkOn) {
            (caret.length == 0 ? style.foreground : isFocused ? style.selection : .unemphasizedSelectedTextBackgroundColor).setFill()
            for segment in segments(of: caret) where segment.rect.insetBy(dx: -2, dy: 0).intersects(rect) {
                (caret.length > 0 ? segment.rect : NSRect(x: segment.rect.minX - 1, y: segment.rect.minY, width: 2, height: segment.rect.height)).fill(using: .sourceOver)
            }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let incoming = ranges.map(\.rangeValue)
        guard !carets.isMirroring, !carets.isFanningOut, isEditable, incoming != carets.ranges else { return }

        if carets.ranges.count > 1, !stillSelecting { carets.history = (carets.history + [carets.ranges]).suffix(32) }
        carets.goalX = nil
        carets.headsAtStart = false
        carets.ranges = ReviewCarets.normalize(incoming, length: textStorage?.length ?? 0)
        carets.primary = carets.ranges.count - 1
        caretsChanged()
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard !carets.isFanningOut else { return }

        super.scrollRangeToVisible(range)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }

        if !Store.shared.isReviewTextFocused { Store.shared.isReviewTextFocused = true }
        caretsChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }

        if Store.shared.isReviewTextFocused { Store.shared.isReviewTextFocused = false }
        carets.findSession = nil
        needsDisplay = true
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window?.firstResponder === self { Store.shared.isReviewTextFocused = false }
        super.viewWillMove(toWindow: newWindow)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard carets.ranges.count > 1, !carets.isFanningOut else { return super.insertText(string, replacementRange: replacementRange) }
        guard !hasMarkedText() else { return commitComposition(string) }

        fanOutEdit { _ in super.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let lengthBefore = textStorage?.length ?? 0
        let anchor = markedRange().location != NSNotFound ? markedRange().location : self.selectedRange().location
        carets.isMirroring = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        carets.isMirroring = false
        let delta = (textStorage?.length ?? 0) - lengthBefore
        guard delta != 0, carets.ranges.count > 1 else { return }

        let primary = carets.primary
        carets.ranges = carets.ranges.enumerated().map { index, caret in index == primary || caret.location <= anchor ? caret : NSRange(location: caret.location + delta, length: caret.length) }
        carets.ranges[primary] = self.selectedRange()
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        guard carets.ranges.count > 1, !carets.isFanningOut, !hasMarkedText() else { return super.doCommand(by: selector) }

        let name = NSStringFromSelector(selector)
        if name == "cancelOperation:" { return performCaretAction(.collapseCursors) }
        if ["delete", "insert", "transpose", "yank"].contains(where: name.hasPrefix) { return fanOutEdit { _ in super.doCommand(by: selector) } }
        if ["move", "select", "page"].contains(where: name.hasPrefix) { return fanOutMovement(selector) }
        super.doCommand(by: selector)
    }

    override func copy(_ sender: Any?) {
        guard carets.ranges.count > 1, let text = textStorage?.mutableString else { return super.copy(sender) }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(carets.ranges.map(text.substring).joined(separator: "\n"), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard carets.ranges.count > 1, isEditable, carets.ranges.contains(where: { $0.length > 0 }) else { return super.cut(sender) }

        copy(sender)
        fanOutEdit { _ in super.delete(nil) }
    }

    override func paste(_ sender: Any?) {
        guard carets.ranges.count > 1, let clipboard = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }

        pasteAtCarets(clipboard)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard carets.ranges.count > 1, let clipboard = NSPasteboard.general.string(forType: .string) else { return super.pasteAsPlainText(sender) }

        pasteAtCarets(clipboard)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let column = carets.column else { return super.mouseDragged(with: event) }

        columnSelect(anchor: column.anchor, focus: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    private func pasteAtCarets(_ clipboard: String) {
        var lines = clipboard.replacing("\r\n", with: "\n").components(separatedBy: "\n")
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        let splitsLines = lines.count == carets.ranges.count
        fanOutEdit { index in super.insertText(splitsLines ? lines[index] : clipboard, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    private func applyCarets(_ ranges: [NSRange], primaryAt hint: Int?) {
        let normalized = ReviewCarets.normalize(ranges, length: textStorage?.length ?? 0)
        let hint = hint ?? carets.ranges[carets.primary].location
        if normalized != carets.ranges { carets.history = (carets.history + [carets.ranges]).suffix(32) }
        carets.goalX = nil
        carets.headsAtStart = false
        carets.column = nil
        carets.ranges = normalized
        carets.primary = normalized.firstIndex { NSLocationInRange(hint, $0) || $0.location == hint } ?? normalized.count - 1
        carets.isMirroring = true
        super.setSelectedRanges([NSValue(range: normalized[carets.primary])], affinity: .downstream, stillSelecting: false)
        carets.isMirroring = false
        caretsChanged()
    }

    private func caretsChanged() {
        needsDisplay = true
        carets.isBlinkOn = true
        carets.blink?.invalidate()
        carets.blink = carets.ranges.count > 1 ? Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(blinkCarets), userInfo: nil, repeats: true) : nil
    }

    @objc private func blinkCarets() {
        guard carets.ranges.count > 1, window?.firstResponder === self else {
            carets.blink?.invalidate()
            carets.blink = nil
            carets.isBlinkOn = true
            return
        }

        carets.isBlinkOn.toggle()
        for (index, caret) in carets.ranges.enumerated() where index != carets.primary && caret.length == 0 {
            for segment in segments(of: caret) { setNeedsDisplay(segment.rect.insetBy(dx: -2, dy: 0)) }
        }
    }

    private func fanOutMovement(_ selector: Selector) {
        let name = NSStringFromSelector(selector)
        let move = name.hasSuffix("AndModifySelection:") ? NSSelectorFromString(name.replacing("AndModifySelection:", with: ":")) : nil
        var headsAtStart = false
        var results: [NSRange] = []
        carets.isFanningOut = true
        for (index, caret) in carets.ranges.enumerated() {
            let anchor = carets.headsAtStart ? NSMaxRange(caret) : caret.location
            super.setSelectedRanges([NSValue(range: move == nil ? caret : NSRange(location: carets.headsAtStart ? caret.location : NSMaxRange(caret), length: 0))], affinity: .downstream, stillSelecting: true)
            super.doCommand(by: move ?? selector)
            let head = selectedRange().location
            results.append(move == nil ? selectedRange() : NSRange(location: min(anchor, head), length: abs(head - anchor)))
            if index == carets.primary { headsAtStart = move != nil && head < anchor }
        }
        carets.isFanningOut = false
        applyCarets(results, primaryAt: results[carets.primary].location)
        carets.headsAtStart = headsAtStart
        scrollRangeToVisible(carets.ranges[carets.primary])
    }

    private func fanOutEdit(_ body: (Int) -> Void) {
        let saved = carets.ranges
        let primary = carets.primary
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        carets.isFanningOut = true
        var results = saved
        for index in saved.indices.reversed() {
            let lengthBefore = textStorage?.length ?? 0
            super.setSelectedRanges([NSValue(range: saved[index])], affinity: .downstream, stillSelecting: true)
            body(index)
            results[index] = selectedRange()
            let delta = (textStorage?.length ?? 0) - lengthBefore
            for later in results.indices where later > index { results[later].location += delta }
        }
        carets.isFanningOut = false
        registerCaretUndo(restoring: saved, primary: primary, redoing: results)
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        applyCarets(results, primaryAt: results[primary].location)
        scrollRangeToVisible(carets.ranges[carets.primary])
    }

    private func commitComposition(_ string: Any) {
        let marked = markedRange()
        let saved = carets.ranges
        let primary = carets.primary
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        carets.isFanningOut = true
        let lengthBefore = textStorage?.length ?? 0
        super.insertText(string, replacementRange: marked)
        let delta = (textStorage?.length ?? 0) - lengthBefore
        var results = saved
        results[primary] = selectedRange()
        for index in saved.indices.reversed() where index != primary {
            let before = textStorage?.length ?? 0
            let target = NSRange(location: saved[index].location + (saved[index].location > marked.location ? delta : 0), length: saved[index].length)
            super.setSelectedRanges([NSValue(range: target)], affinity: .downstream, stillSelecting: true)
            super.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
            results[index] = selectedRange()
            let step = (textStorage?.length ?? 0) - before
            for later in results.indices where later > index || later == primary && primary > index { results[later].location += step }
        }
        carets.isFanningOut = false
        registerCaretUndo(restoring: saved, primary: primary, redoing: results)
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        applyCarets(results, primaryAt: results[primary].location)
    }

    // Registered last in the group, so it runs before the text undo; the async apply lands after the text view moves its selection.
    private func registerCaretUndo(restoring ranges: [NSRange], primary: Int, redoing redo: [NSRange]) {
        undoManager?.registerUndo(withTarget: self) { view in
            view.registerCaretUndo(restoring: redo, primary: primary, redoing: ranges)
            DispatchQueue.main.async { view.applyCarets(ranges, primaryAt: ranges[min(primary, ranges.count - 1)].location) }
        }
    }

    private func findQuery() -> (needle: String, matching: ReviewCarets.Matching, word: NSRange?)? {
        guard let text = textStorage?.mutableString else { return nil }

        if let session = carets.findSession, session.carets == carets.ranges { return (session.needle, session.matching, nil) }
        let primary = carets.ranges[carets.primary]
        guard primary.length == 0 else { return (text.substring(with: primary), .substringIgnoreCase, nil) }
        guard let word = ReviewCarets.wordRange(touching: primary.location, in: text) else { return nil }

        return (text.substring(with: word), carets.ranges.count == 1 ? .wholeWordMatchCase : .substringIgnoreCase, word)
    }

    private func addNextOccurrence() {
        guard let text = textStorage?.mutableString else { return }

        let primary = carets.ranges[carets.primary]
        let primaryText = text.substring(with: primary).lowercased()
        let caretsShareText = primary.length > 0 && carets.ranges.allSatisfy { text.substring(with: $0).lowercased() == primaryText }
        guard carets.findSession?.carets == carets.ranges || carets.ranges.count == 1 || caretsShareText else {
            let words = carets.ranges.map { $0.length > 0 ? $0 : ReviewCarets.wordRange(touching: $0.location, in: text) ?? $0 }
            return applyCarets(words, primaryAt: words[carets.primary].location)
        }
        guard let query = findQuery(), let match = query.word ?? ReviewCarets.nextOccurrence(after: NSMaxRange(primary), of: query.needle, in: text, matching: query.matching) else { return }

        applyCarets(carets.ranges + [match], primaryAt: match.location)
        carets.findSession = (query.needle, query.matching, carets.ranges)
        scrollRangeToVisible(match)
    }

    private func moveLastSelectionToNextOccurrence() {
        guard let text = textStorage?.mutableString, let query = findQuery(), let match = query.word ?? ReviewCarets.nextOccurrence(after: NSMaxRange(carets.ranges[carets.primary]), of: query.needle, in: text, matching: query.matching) else { return }

        var updated = carets.ranges
        updated[carets.primary] = match
        applyCarets(updated, primaryAt: match.location)
        carets.findSession = (query.needle, query.matching, carets.ranges)
        scrollRangeToVisible(match)
    }

    private func selectAllOccurrences() {
        guard let text = textStorage?.mutableString, let query = findQuery() else { return }

        let matches = ReviewCarets.occurrences(of: query.needle, in: text, matching: query.matching)
        guard !matches.isEmpty else { return }

        let primary = carets.ranges[carets.primary]
        let primaryMatch = matches.first { $0.location <= NSMaxRange(primary) && primary.location <= NSMaxRange($0) } ?? matches[0]
        applyCarets(matches, primaryAt: primaryMatch.location)
        carets.findSession = (query.needle, query.matching, carets.ranges)
    }

    private func addCursorsToLineEnds() {
        let length = textStorage?.length ?? 0
        let ends = carets.ranges.flatMap { caret in
            let first = lineStarts.partitioningIndex { $0 > caret.location } - 1
            let last = max(lineStarts.partitioningIndex { $0 >= NSMaxRange(caret) } - 1, first)
            return (first...last).map { NSRange(location: $0 + 1 < lineStarts.count ? lineStarts[$0 + 1] - 1 : length, length: 0) }
        }
        applyCarets(ends, primaryAt: ends.last?.location)
    }

    private func addCursor(lineOffset: Int) {
        let anchor = lineOffset < 0 ? carets.ranges[0] : carets.ranges[carets.ranges.count - 1]
        let probe = lineOffset < 0 ? anchor.location : NSMaxRange(anchor)
        let line = lineStarts.partitioningIndex { $0 > probe } - 1 + lineOffset
        guard lineStarts.indices.contains(line), let caret = segments(of: NSRange(location: probe, length: 0)).first?.rect, let target = segments(of: NSRange(location: lineStarts[line], length: 0)).first?.rect else { return }

        let goalX = carets.goalX ?? caret.minX
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : textStorage?.length ?? 0
        let index = min(max(characterIndexForInsertion(at: NSPoint(x: goalX, y: target.midY)), lineStarts[line]), end)
        applyCarets(carets.ranges + [NSRange(location: index, length: 0)], primaryAt: index)
        carets.goalX = goalX
        scrollRangeToVisible(NSRange(location: index, length: 0))
    }

    private func columnSelect(anchor: Int, focus: Int) {
        let length = textStorage?.length ?? 0
        let anchorLine = lineStarts.partitioningIndex { $0 > anchor } - 1
        let focusLine = lineStarts.partitioningIndex { $0 > focus } - 1
        let lower = min(anchor - lineStarts[anchorLine], focus - lineStarts[focusLine])
        let upper = max(anchor - lineStarts[anchorLine], focus - lineStarts[focusLine])
        let ranges = (min(anchorLine, focusLine)...max(anchorLine, focusLine)).map { line in
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
            let from = min(lineStarts[line] + lower, end)
            return NSRange(location: from, length: min(lineStarts[line] + upper, end) - from)
        }
        applyCarets(ranges, primaryAt: focus)
        carets.column = (anchor, focus)
    }
}
