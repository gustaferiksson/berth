#if DEBUG
import AppKit
import BerthCore

extension Snapshot {
    static func testConversationSelection(store: Store, tab: Tab, window: NSWindow, save: (String) -> Void) async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            print("select: FAIL timed out")
            exit(1)
        }
        let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
        let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
        method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
        method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
        window.becomeKey()

        let results = await heavyConversationTurns > 0
            ? [selectAllLoadedTurns(store: store, tab: tab, window: window)]
            : [dragAcrossItems(window: window, save: save), shiftClick(window: window), selectAllFixture(window: window)]
        let passed = results.allSatisfy(\.self)
        print(passed ? "select: ALL PASS" : "select: FAILED")
        ProcessAncestry.hangUpDescendants()
        exit(passed ? 0 : 1)
    }

    private static func dragAcrossItems(window: NSWindow, save: (String) -> Void) async -> Bool {
        guard let first = await reply(containing: "I'll start with the export code", in: window, revealing: true),
              let last = await reply(containing: "Fixed. The export", in: window),
              let from = point(in: first, before: "export code"),
              let to = point(in: last, after: "UTC")
        else { return fail("drag", "fixture replies are not on screen") }

        await click(from: from, to: to, in: window)
        save(".selection.png")
        return check("drag", copied(), inOrder: ["export code and the CI log", "The date formatter has no fixed time zone", "formatter.timeZone = TimeZone", "UTC"], excluding: ["I'll start with the", "Why does the usage export"])
    }

    private static func shiftClick(window: NSWindow) async -> Bool {
        guard let first = await reply(containing: "The date formatter has no fixed", in: window),
              let last = await reply(containing: "Fixed. The export", in: window),
              let from = point(in: first, before: "date formatter"),
              let to = point(in: last, after: "Both export")
        else { return fail("shift-click", "fixture replies are not on screen") }

        await click(from: from, to: from, in: window)
        await click(from: to, to: to, in: window, modifiers: .shift)
        return check("shift-click", copied(), inOrder: ["date formatter has no fixed", "Both export"], excluding: ["export code and the CI log"])
    }

    private static func selectAllFixture(window: NSWindow) async -> Bool {
        guard let view = await reply(containing: "Fixed. The export", in: window), let point = point(in: view, before: "Fixed.") else { return fail("select all", "fixture reply is not on screen") }

        await click(from: point, to: point, in: window)
        NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        try? await Task.sleep(for: .milliseconds(300))
        return check("select all", copied(), inOrder: ["I'll start with the export code", "The date formatter has no fixed time zone", "Fixed. The export grouped rows", "The migration check is still running"])
    }

    private static func selectAllLoadedTurns(store: Store, tab: Tab, window: NSWindow) async -> Bool {
        let replies = store.conversationModels[tab.id]?.turns.flatMap { turn in turn.parts.compactMap { part -> String? in if case let .reply(entry) = part { entry.text } else { nil } } } ?? []
        guard let firstBatch = replies.first?.firstMatch(of: /Ledger batch (\d+)/)?.1,
              let lastBatch = replies.last?.firstMatch(of: /Ledger batch (\d+)/)?.1,
              let view = await reply(containing: "Ledger batch \(lastBatch)", in: window),
              let point = point(in: view, before: "the exact input")
        else { return fail("select all loaded turns", "the last heavy reply is not on screen") }

        await click(from: point, to: point, in: window)
        NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        try? await Task.sleep(for: .milliseconds(300))
        return check("select all loaded turns", copied(), inOrder: ["Ledger batch \(firstBatch)\n", "Ledger batch \(lastBatch)\n"])
    }

    private static func textViews(in view: NSView) -> [ConversationNSTextView] {
        (view as? ConversationNSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    private static func reply(containing text: String, in window: NSWindow, revealing: Bool = false) async -> ConversationNSTextView? {
        guard let content = window.contentView, let view = textViews(in: content).first(where: { $0.string.contains(text) }) else { return nil }
        guard revealing else { return view.visibleRect.isEmpty ? nil : view }

        view.scrollToVisible(view.bounds)
        try? await Task.sleep(for: .milliseconds(500))
        return textViews(in: content).first { $0.string.contains(text) && !$0.visibleRect.isEmpty }
    }

    private static func point(in view: ConversationNSTextView, before text: String) -> NSPoint? {
        let range = (view.string as NSString).range(of: text)
        return range.location == NSNotFound ? nil : point(in: view, offset: range.location, edge: \.minX)
    }

    private static func point(in view: ConversationNSTextView, after text: String) -> NSPoint? {
        let range = (view.string as NSString).range(of: text)
        return range.location == NSNotFound ? nil : point(in: view, offset: NSMaxRange(range) - 1, edge: \.maxX)
    }

    private static func point(in view: ConversationNSTextView, offset: Int, edge: KeyPath<NSRect, CGFloat>) -> NSPoint? {
        guard let manager = view.textLayoutManager,
              let storage = view.textContentStorage,
              let start = storage.location(storage.documentRange.location, offsetBy: offset),
              let end = storage.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end)
        else { return nil }

        manager.ensureLayout(for: range)
        var frame = NSRect.null
        manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            frame = segment
            return false
        }
        guard !frame.isNull, view.visibleRect.contains(NSPoint(x: frame.midX, y: frame.midY)) else { return nil }

        return view.convert(NSPoint(x: (frame[keyPath: edge] + frame.midX) / 2, y: frame.midY), to: nil)
    }

    private static func click(from start: NSPoint, to end: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) async {
        let steps = start == end ? 0 : 12
        let moves = steps == 0 ? [] : (1...steps).map { NSPoint(x: start.x + (end.x - start.x) * Double($0) / Double(steps), y: start.y + (end.y - start.y) * Double($0) / Double(steps)) }
        let event = { (type: NSEvent.EventType, point: NSPoint) in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        for queued in moves.compactMap({ event(.leftMouseDragged, $0) }) + [event(.leftMouseUp, end)].compactMap(\.self) {
            NSApp.postEvent(queued, atStart: false)
        }
        if let down = event(.leftMouseDown, start) { window.sendEvent(down) }
        try? await Task.sleep(for: .milliseconds(600))
    }

    private static func copied() -> String {
        let target = NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil)
        print("select: copy goes to \(target.map { String(describing: type(of: $0)) } ?? "nothing")")
        guard let view = target as? NSTextView else { return "" }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        _ = view.writeSelection(to: pasteboard, types: [.string])
        let text = pasteboard.string(forType: .string) ?? ""
        print("select: copied \(text.debugDescription)")
        return text
    }

    private static func check(_ name: String, _ text: String, inOrder expected: [String], excluding unexpected: [String] = []) -> Bool {
        var cursor = text.startIndex
        for phrase in expected {
            guard let range = text.range(of: phrase, range: cursor..<text.endIndex) else { return fail(name, "missing \(phrase.debugDescription) in order") }

            cursor = range.upperBound
        }
        if let phrase = unexpected.first(where: text.contains) { return fail(name, "unexpected \(phrase.debugDescription)") }

        print("select: \(name) PASS")
        return true
    }

    private static func fail(_ name: String, _ reason: String) -> Bool {
        print("select: \(name) FAIL \(reason)")
        return false
    }
}
#endif
