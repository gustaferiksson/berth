import BerthCore
import Foundation
import GhosttyTerminal
import SwiftUI

struct LauncherRowFrame<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let secondary: [String]
    let isHighlighted: Bool
    let monospacedSecondary: Bool
    let snippets: [AttributedString]
    let trailing: Trailing

    @Environment(\.ghosttyTheme) private var theme

    init(symbol: String, tint: Color, title: String, secondary: [String] = [], isHighlighted: Bool = false, monospacedSecondary: Bool = false, snippets: [AttributedString] = [], @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.secondary = secondary
        self.isHighlighted = isHighlighted
        self.monospacedSecondary = monospacedSecondary
        self.snippets = snippets
        self.trailing = trailing()
    }

    var body: some View {
        let accent = Color.accentColor
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.16), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !secondary.isEmpty {
                    Text(verbatim: secondary.joined(separator: " · "))
                        .font(monospacedSecondary ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(monospacedSecondary ? .middle : .tail)
                }

                ForEach(Array(snippets.enumerated()), id: \.offset) { _, snippet in
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing

            if isHighlighted {
                Text("↩")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 20)
                    .background(theme.foreground.opacity(0.12), in: .rect(cornerRadius: 5))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background {
            if isHighlighted {
                let shape = RoundedRectangle(cornerRadius: 12)
                shape.fill(accent.opacity(0.20))
                    .overlay { shape.strokeBorder(accent.opacity(0.35), lineWidth: 1) }
            }
        }
        .contentShape(.rect)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

struct LauncherSectionHeader: View {
    let title: String
    let count: Int?

    init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack {
            Text(verbatim: title)
                .tracking(0.35)
            Spacer()
            if let count {
                Text(verbatim: String(count))
                    .monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct LauncherBadge: View {
    let text: String
    let symbol: String?
    let tint: Color?

    @Environment(\.ghosttyTheme) private var theme

    init(_ text: String, symbol: String? = nil, tint: Color? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(tint?.opacity(0.16) ?? theme.foreground.opacity(0.09), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

struct LauncherLabelCapsule: View {
    let name: String
    let hex: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let base = (digits.count == 6 ? UInt32(digits, radix: 16) : nil).map { value in
            Color(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
        let tint = base?.mix(with: colorScheme == .dark ? .white : .black, by: colorScheme == .dark ? 0.5 : 0.56)

        Text(verbatim: name)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint ?? Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .frame(maxWidth: 108)
            .background(base?.opacity(0.18) ?? theme.foreground.opacity(0.09), in: .capsule)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct LauncherScopePicker<Scope: Hashable>: View {
    let scopes: [(mode: Scope, title: String)]
    let selection: Scope
    let previousSelection: Scope?
    let select: (Scope) -> Void

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pill
    @State private var displayedSelection: Scope?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(scopes, id: \.mode) { scope, title in
                Button { select(scope) } label: {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(scope == selection ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if scope == (displayedSelection ?? (reduceMotion ? nil : previousSelection) ?? selection) {
                                Capsule()
                                    .fill(theme.foreground.opacity(0.14))
                                    .matchedGeometryEffect(id: "selection", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(scope == selection ? .isSelected : [])
            }
        }
        .padding(3)
        .background(theme.foreground.opacity(0.07), in: .capsule)
        .help("Switch launcher scope (⇥)")
        .task(id: selection) {
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                displayedSelection = selection
            }
        }
    }
}

struct LauncherKeyHint: View {
    let key: String
    let label: String

    @Environment(\.ghosttyTheme) private var theme

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: key)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .frame(minWidth: 21, minHeight: 19)
                .background(theme.foreground.opacity(0.12), in: .rect(cornerRadius: 5))
                .fixedSize()

            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }
}

struct LauncherMessage: View {
    let symbol: String
    let title: String
    let detail: String?
    let isLoading: Bool

    init(symbol: String, title: String, detail: String? = nil, isLoading: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.isLoading = isLoading
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 34)
            .accessibilityHidden(true)

            Text(verbatim: title)
                .font(.headline)

            if let detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .combine)
    }
}
