import SwiftUI

struct ConversationPickerMenu<Element, ID: Hashable, Row: View>: View {
    let items: [Element]
    let id: KeyPath<Element, ID>
    let selected: ID?
    let label: String
    let help: (Element) -> String
    let choose: (Element) -> Void
    @ViewBuilder let row: (Element) -> Row
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let rowHeight = 32.0
        let selected = selected ?? items.first?[keyPath: id]
        let shape = RoundedRectangle(cornerRadius: 14)
        let color = theme.chrome ?? Color(nsColor: .controlBackgroundColor)

        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: id) { item in
                        let isSelected = item[keyPath: id] == selected
                        Button {
                            choose(item)
                        } label: {
                            row(item)
                                .lineLimit(1)
                                .foregroundStyle(theme.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: rowHeight)
                                .background(Color.accentColor.opacity(isSelected ? 0.15 : 0), in: .rect(cornerRadius: 8))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .help(help(item))
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: rowHeight * Double(min(items.count, 6)))
            .onChange(of: selected) {
                if let selected { scroll.scrollTo(selected) }
            }
        }
        .padding(.vertical, 4)
        .background(color.mix(with: .accentColor, by: 0.04), in: shape)
        .overlay { shape.strokeBorder(theme.foreground.opacity(0.12)).allowsHitTesting(false) }
        .accessibilityLabel(label)
    }
}
