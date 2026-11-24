import AppKit
import BerthCore
import Observation
import SwiftUI

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
        field.insertText(command.name + " ", replacementRange: completion.replacementRange)
        return true
    }
}

struct ConversationSlashMenu: View {
    let picker: ConversationSlashPicker
    let matches: [SlashCommand]
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let rowHeight = 32.0
        let selected = matches.first { $0.name == picker.selectedName }?.name ?? matches.first?.name
        let shape = RoundedRectangle(cornerRadius: 14)
        let color = theme.chrome ?? Color(nsColor: .controlBackgroundColor)

        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches, id: \.name) { command in
                        Button {
                            _ = picker.accept(command)
                        } label: {
                            HStack(spacing: 10) {
                                Text(verbatim: command.name)
                                    .font(.system(.callout, design: .monospaced).weight(.medium))
                                    .foregroundStyle(theme.foreground)
                                    .layoutPriority(1)
                                Text(verbatim: command.summary)
                                    .font(.callout)
                                Spacer(minLength: 0)
                                Text(verbatim: command.source)
                                    .font(.caption)
                            }
                            .lineLimit(1)
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: rowHeight)
                            .background(Color.accentColor.opacity(selected == command.name ? 0.15 : 0), in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == command.name ? .isSelected : [])
                        .help(command.argumentHint.map { "\(command.name) \($0)" } ?? command.summary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: rowHeight * Double(min(matches.count, 6)))
            .onChange(of: selected) {
                if let selected { scroll.scrollTo(selected) }
            }
        }
        .padding(.vertical, 4)
        .background(color.mix(with: .accentColor, by: 0.04), in: shape)
        .overlay { shape.strokeBorder(theme.foreground.opacity(0.12)).allowsHitTesting(false) }
        .accessibilityLabel("Slash commands")
    }
}
