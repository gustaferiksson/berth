import AppKit
import BerthCore
import SwiftUI

extension EnvironmentValues {
    @Entry var conversationSelection: ConversationSelection?
    @Entry var conversationExpansion: ConversationExpansion?
}

@Observable
final class ConversationExpansion {
    var keys: Set<String> = []

    func toggle(_ key: String) {
        if keys.remove(key) == nil { keys.insert(key) }
    }

    #if DEBUG
    func expand(_ turns: [Turn]) {
        for turn in turns {
            if let prompt = turn.prompt {
                let id = "prompt:\(turn.id)"
                keys.insert(id + "#bubble")
                for index in prompt.text.matches(of: ConversationPrompt.fence).indices { keys.insert(id + "#code\(index)") }
            }
            for part in turn.parts {
                guard case let .reply(entry) = part else { continue }

                let blocks = MarkdownAttributedString.codeBlocks(in: MarkdownBlock.blocks(in: entry.text))
                for index in blocks.indices { keys.insert("reply:\(entry.id)#code\(index)") }
            }
        }
    }
    #endif
}

extension NSAttributedString.Key {
    static let conversationCopyText = NSAttributedString.Key("berth.conversationCopyText")
}

@MainActor
final class ConversationSelection {
    private struct Position {
        let item: String
        let offset: Int
    }

    private struct Item {
        let id: String
        let text: () -> NSAttributedString
    }

    private let expansion: ConversationExpansion
    private let turns: () -> [Turn]
    private let views = NSHashTable<ConversationNSTextView>.weakObjects()
    private var order: [String: Int] = [:]
    private var anchor: Position?
    private var focus: Position?
    private var displayScale: CGFloat?
    private var theme = GhosttyTheme(values: [:])
    private var monitor: Any?
    private var lastDrag: NSEvent?
    private var autoscrolling: Task<Void, Never>?

    init(expansion: ConversationExpansion, turns: @escaping () -> [Turn]) {
        self.expansion = expansion
        self.turns = turns
    }

    var hasSelection: Bool {
        guard let (start, end) = ordered() else { return false }

        return start.item != end.item || start.offset != end.offset
    }

    static func plainText(_ text: NSAttributedString, in range: NSRange) -> String {
        var result = ""
        text.enumerateAttribute(.conversationCopyText, in: range) { value, run, _ in
            result += value as? String ?? (text.string as NSString).substring(with: run)
        }
        return result
    }

    func register(_ view: ConversationNSTextView, displayScale: CGFloat) {
        self.displayScale = displayScale
        views.add(view)
        theme = view.theme
        view.showSelection(range(for: view))
    }

    func begin(in view: ConversationNSTextView, at offset: Int, extending: Bool) -> Bool {
        refresh()
        guard let id = view.selectionID, order[id] != nil else { return false }

        let position = Position(item: id, offset: offset)
        if !extending || anchor == nil { anchor = position }
        focus = position
        apply()
        track()
        return true
    }

    func handOff(from view: ConversationNSTextView, in window: NSWindow) {
        guard hasSelection, let next = views.allObjects.first(where: { $0 !== view && $0.window === window }) else { return }

        window.makeFirstResponder(next)
    }

    func adopt(_ view: ConversationNSTextView) {
        refresh()
        guard let id = view.selectionID, order[id] != nil else { return }

        let range = view.selectedRange()
        anchor = Position(item: id, offset: range.location)
        focus = Position(item: id, offset: NSMaxRange(range))
        apply()
    }

    func selectAll(from view: ConversationNSTextView) -> Bool {
        let items = refresh()
        guard let id = view.selectionID, order[id] != nil, let first = items.first, let last = items.last else { return false }

        anchor = Position(item: first.id, offset: 0)
        focus = Position(item: last.id, offset: last.text().length)
        apply()
        return true
    }

    func focusLeft(_ view: ConversationNSTextView) {
        Task { [weak self, weak window = view.window] in
            guard let self, (window?.firstResponder as? ConversationNSTextView)?.selection !== self else { return }

            clear()
        }
    }

    func clear() {
        anchor = nil
        focus = nil
        apply()
    }

    func copiedText() -> String {
        let items = refresh()
        guard let (start, end) = ordered(), let first = order[start.item], let last = order[end.item] else { return "" }

        return items[first...last].map { item in
            let text = item.text()
            let lower = min(item.id == start.item ? start.offset : 0, text.length)
            let upper = min(item.id == end.item ? end.offset : text.length, text.length)
            return Self.plainText(text, in: NSRange(location: lower, length: max(0, upper - lower)))
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private func track() {
        monitor.map(NSEvent.removeMonitor)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }

            if event.type == .leftMouseUp { finish(event) } else { follow(event) }
            return nil
        }
    }

    private func follow(_ event: NSEvent) {
        lastDrag = event
        drag(to: event.locationInWindow)
        guard autoscroll(with: event), autoscrolling == nil else { return }

        autoscrolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let event = lastDrag, autoscroll(with: event) else { break }

                drag(to: event.locationInWindow)
            }
            self?.autoscrolling = nil
        }
    }

    private func finish(_ event: NSEvent) {
        drag(to: event.locationInWindow)
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
        lastDrag = nil
        autoscrolling?.cancel()
    }

    private func autoscroll(with event: NSEvent) -> Bool {
        views.allObjects.first { $0.window === event.window }?.autoscroll(with: event) ?? false
    }

    private func drag(to point: NSPoint) {
        guard let position = position(at: point) else { return }

        focus = position
        apply()
    }

    @discardableResult
    private func refresh() -> [Item] {
        let theme = theme
        let displayScale = displayScale
        let expanded = expansion.keys
        let items = turns().flatMap { turn -> [Item] in
            let prompt = turn.prompt.flatMap { entry -> Item? in
                guard entry.name != "bash", !entry.text.isEmpty else { return nil }

                let id = "prompt:\(turn.id)"
                return Item(id: id) { ConversationPrompt.attributed(entry.text, theme: theme, displayScale: displayScale, itemID: id, expanded: expanded) }
            }
            let replies = turn.parts.compactMap { part -> Item? in
                guard case let .reply(entry) = part else { return nil }

                let id = "reply:\(entry.id)"
                return Item(id: id) { ConversationMarkdown.rendered(entry.text, theme: theme, itemID: id, expanded: expanded) }
            }
            return (prompt.map { [$0] } ?? []) + replies
        }
        order = Dictionary(items.enumerated().map { ($1.id, $0) }) { first, _ in first }
        return items
    }

    private func ordered() -> (start: Position, end: Position)? {
        guard let anchor, let focus, let anchorIndex = order[anchor.item], let focusIndex = order[focus.item] else { return nil }

        return (anchorIndex, anchor.offset) <= (focusIndex, focus.offset) ? (anchor, focus) : (focus, anchor)
    }

    private func range(for view: ConversationNSTextView) -> NSRange? {
        guard let id = view.selectionID,
              let index = order[id],
              let (start, end) = ordered(),
              let first = order[start.item],
              let last = order[end.item],
              (first...last).contains(index)
        else { return nil }

        let length = (view.string as NSString).length
        let lower = min(index == first ? start.offset : 0, length)
        let upper = min(index == last ? end.offset : length, length)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private func apply() {
        for view in views.allObjects where view.window != nil {
            view.showSelection(range(for: view))
        }
    }

    private func position(at point: NSPoint) -> Position? {
        let live = views.allObjects
            .compactMap { view in view.window == nil ? nil : view.selectionID.flatMap { id in order[id].map { (index: $0, id: id, view: view) } } }
            .sorted { $0.index < $1.index }
        for (_, id, view) in live {
            let frame = view.convert(view.bounds, to: nil)
            if point.y > frame.maxY { return Position(item: id, offset: 0) }
            if point.y >= frame.minY { return Position(item: id, offset: view.characterOffset(at: view.convert(point, from: nil))) }
        }
        return live.last.map { Position(item: $0.id, offset: ($0.view.string as NSString).length) }
    }
}
