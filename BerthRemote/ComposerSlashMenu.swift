import SwiftUI

struct ComposerSlashMenu: View {
    let matches: [SlashCommand]
    let selected: String
    let pick: (SlashCommand) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = 46.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ComposerLayout.cornerRadius)

        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches, id: \.name) { command in
                        Button { pick(command) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(verbatim: command.name)
                                        .font(.subheadline.monospaced().weight(.medium))
                                        .foregroundStyle(.primary)
                                        .layoutPriority(1)
                                    Spacer(minLength: 0)
                                    Text(verbatim: command.source)
                                        .font(.caption2)
                                }
                                if !command.summary.isEmpty {
                                    Text(verbatim: command.summary)
                                        .font(.footnote)
                                }
                            }
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                            .background(Color.accentColor.opacity(selected == command.name ? 0.12 : 0), in: .rect(cornerRadius: 12))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: command.name))
                        .accessibilityValue(Text(verbatim: [command.summary, command.source].filter { !$0.isEmpty }.joined(separator: ", ")))
                        .accessibilityHint(Text(verbatim: command.argumentHint.map { "Arguments \($0)" } ?? "Inserts the command"))
                        .accessibilityAddTraits(selected == command.name ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 5)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: rowHeight * Double(min(matches.count, 5)))
            .onChange(of: selected) { scroll.scrollTo(selected) }
        }
        .padding(.vertical, 5)
        .background {
            shape.fill(.background)
                .overlay { shape.fill(Color.accentColor.opacity(0.05)) }
        }
        .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slash commands")
    }
}
