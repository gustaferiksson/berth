import AppKit
import SwiftUI

struct ConversationPickerRow {
    let name: String
    let detail: String
    let symbol: String
    var source: String?
    let help: String
    var matches: [Int] = []
    var isDangerous = false

    func highlightedName(isSelected: Bool) -> AttributedString {
        var title = AttributedString(name)
        for offset in matches {
            guard let range = Range(NSRange(location: offset, length: 1), in: title) else { continue }

            title[range].foregroundColor = isSelected ? .white : isDangerous ? .red : .accentColor
            title[range].underlineStyle = .single
        }
        return title
    }
}

struct ConversationPickerMenu<Element, ID: Hashable>: View {
    let items: [Element]
    let id: KeyPath<Element, ID>
    let selected: ID?
    let label: String
    let choose: (Element) -> Void
    let row: (Element) -> ConversationPickerRow

    var body: some View {
        let rowHeight = 23.0
        let selected = selected ?? items.first?[keyPath: id]
        let shape = RoundedRectangle(cornerRadius: 8)

        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items, id: id) { item in
                        let content = row(item)
                        let isSelected = item[keyPath: id] == selected
                        Button {
                            choose(item)
                        } label: {
                            rowLabel(content, isSelected: isSelected)
                                .padding(.horizontal, 6)
                                .frame(height: rowHeight)
                                .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear, in: .rect(cornerRadius: 4))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityLabel(content.isDangerous ? "\(content.name), dangerous" : content.name)
                        .accessibilityHint(content.detail)
                        .help(content.help)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: rowHeight * Double(min(items.count, 8)))
            .onChange(of: selected, initial: true) {
                if let selected { scroll.scrollTo(selected) }
            }
        }
        .padding(.vertical, 4)
        .background { ConversationPickerMaterial() }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.23), radius: 8, y: 3)
        .accessibilityLabel(label)
    }

    private func rowLabel(_ content: ConversationPickerRow, isSelected: Bool) -> some View {
        let foreground: Color = isSelected ? .white : content.isDangerous ? .red : .primary
        let secondary: Color = isSelected ? .white.opacity(0.8) : .secondary

        return HStack(spacing: 7) {
            Image(systemName: content.isDangerous ? "exclamationmark.triangle.fill" : content.symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 14)
                .foregroundStyle(content.isDangerous ? foreground : secondary)
                .accessibilityHidden(true)
            Text(content.highlightedName(isSelected: isSelected))
                .font(.system(size: 13))
                .foregroundStyle(foreground)
                .layoutPriority(1)
            if !content.detail.isEmpty {
                Text(verbatim: content.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
            }
            Spacer(minLength: 0)
            if let source = content.source {
                Text(verbatim: source)
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
            }
        }
        .lineLimit(1)
    }
}

private struct ConversationPickerMaterial: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
}
