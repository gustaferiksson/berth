import AppKit
import BerthCore
import SwiftUI

extension EnvironmentValues {
    @Entry var conversationSelection: ConversationSelection?
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

    private let turns: () -> [Turn]
    private let views = NSHashTable<ConversationNSTextView>.weakObjects()
    private var order: [String: Int] = [:]
    private var anchor: Position?
    private var focus: Position?
    private var theme = GhosttyTheme(values: [:])
    private(set) var isDragging = false

    init(turns: @escaping () -> [Turn]) {
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

    func register(_ view: ConversationNSTextView) {
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
        isDragging = true
        apply()
        return true
    }

    func drag(to point: NSPoint) {
        guard isDragging, let position = position(at: point) else { return }

        focus = position
        apply()
    }

    func endDrag() {
        isDragging = false
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

            anchor = nil
            focus = nil
            apply()
        }
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

    @discardableResult
    private func refresh() -> [Item] {
        let theme = theme
        let items = turns().flatMap { turn -> [Item] in
            let prompt = turn.prompt.flatMap { entry in
                entry.name == "bash" || entry.text.isEmpty ? nil : Item(id: "prompt:\(turn.id)") { ConversationPrompt.attributed(entry.text, theme: theme) }
            }
            let replies = turn.parts.compactMap { part -> Item? in
                guard case let .reply(entry) = part else { return nil }

                return Item(id: "reply:\(entry.id)") { ConversationMarkdown.rendered(entry.text, theme: theme) }
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
