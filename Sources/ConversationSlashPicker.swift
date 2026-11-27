import AppKit
import BerthCore
import Observation
import os

@Observable
final class ConversationSlashPicker {
    struct Scope: Hashable, Sendable {
        let folder: String
        let agent: Agent
    }

    private(set) var query: String?
    private(set) var selectedName: String?
    var commands: [SlashCommand] = []
    @ObservationIgnored weak var field: ComposerTextView?
    @ObservationIgnored private var dismissedQuery: String?

    var matches: [SlashCommand] {
        guard let query else { return [] }

        return SlashCommand.matching(query, in: commands)
    }

    func update(query: String?) {
        if let query, query == dismissedQuery { return }

        dismissedQuery = nil
        guard query != self.query else { return }

        self.query = query
        selectedName = nil
    }

    func dismiss() -> Bool {
        guard let query else { return false }

        dismissedQuery = query
        self.query = nil
        selectedName = nil
        return true
    }

    func move(by offset: Int) -> Bool {
        let matches = matches
        guard !matches.isEmpty else { return false }

        let current = matches.firstIndex { $0.name == selectedName } ?? 0
        selectedName = matches[(current + offset + matches.count) % matches.count].name
        return true
    }

    func accept(_ command: SlashCommand? = nil) -> Bool {
        let matches = matches
        guard let command = command ?? matches.first(where: { $0.name == selectedName }) ?? matches.first,
              let field, let completion = field.slashCompletion, completion.query == query else { return false }

        field.window?.makeFirstResponder(field)
        let before = field.selectedRange().location
        field.insertText(command.name + " ", replacementRange: completion.replacementRange)
        composerLog.info("slash accept insertText caret \(before, privacy: .public) to \(field.selectedRange().location, privacy: .public)")
        return true
    }
}
