import AppKit
import BerthCore
import Foundation
import GhosttyTerminal
import SwiftUI

enum LauncherGlyph: ExpressibleByStringLiteral {
    case symbol(String)
    case octicon(Octicon)

    init(stringLiteral value: String) {
        self = .symbol(value)
    }

    @ViewBuilder
    func image(octiconSize: CGFloat = 14) -> some View {
        switch self {
        case let .symbol(name): Image(systemName: name)
        case let .octicon(octicon): OcticonImage(octicon, size: octiconSize)
        }
    }
}

struct LauncherRowFrame<Trailing: View>: View {
    let symbol: LauncherGlyph
    let tint: Color
    let title: String
    let secondary: [String]
    let isHighlighted: Bool
    let monospacedSecondary: Bool
    let snippets: [AttributedString]
    let trailing: Trailing

    @Environment(\.ghosttyTheme) private var theme

    init(symbol: LauncherGlyph, tint: Color, title: String, secondary: [String] = [], isHighlighted: Bool = false, monospacedSecondary: Bool = false, snippets: [AttributedString] = [], @ViewBuilder trailing: () -> Trailing) {
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
        HStack(spacing: 10) {
            symbol.image()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(isHighlighted ? theme.foreground.opacity(0.10) : .clear, in: .rect(cornerRadius: 8))
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
            Spacer()
            if let count {
                Text(verbatim: String(count))
                    .monospacedDigit()
            }
        }
        .font(.caption.weight(.medium))
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
    let symbol: LauncherGlyph?
    let tint: Color?

    @Environment(\.ghosttyTheme) private var theme

    init(_ text: String, symbol: LauncherGlyph? = nil, tint: Color? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                symbol.image()
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

struct LauncherRowDetail: View {
    let text: String
    let symbol: LauncherGlyph?
    let tint: Color?

    init(_ text: String, symbol: LauncherGlyph? = nil, tint: Color? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                symbol.image(octiconSize: 11)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(verbatim: text)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(tint ?? Color.secondary)
        .accessibilityElement(children: .combine)
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

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 5) {
            LauncherKeycap(key: key)

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

struct LauncherKeycap: View {
    let key: String

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Text(verbatim: key)
            .font(.caption.monospaced().weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .frame(minWidth: 21, minHeight: 19)
            .background(theme.foreground.opacity(0.12), in: .rect(cornerRadius: 5))
            .fixedSize()
    }
}

struct LauncherAction {
    let title: String
    let symbol: String
    var key: String?
    var isEnabled = true
    let perform: () -> Void
}

struct LauncherActionPanel: View {
    let actions: [LauncherAction]
    let highlighted: Int?
    let shortcuts: [(key: String, title: String)]
    let select: (LauncherAction) -> Void

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if actions.isEmpty {
                            Text("No actions available")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .padding(.horizontal, 8)
                        }
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                            row(action, isHighlighted: index == highlighted)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .frame(height: CGFloat(min(max(actions.count, 1), 5) * 28 + 12))
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: highlighted) {
                    if let highlighted { proxy.scrollTo(highlighted) }
                }
            }
            if !shortcuts.isEmpty {
                Divider()
                HStack(spacing: 10) {
                    ForEach(shortcuts, id: \.key) { shortcut in
                        LauncherKeyHint(shortcut.key, shortcut.title)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
        }
        .frame(idealWidth: 265, maxWidth: 265)
        .background(theme.chrome ?? Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.foreground.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Actions")
    }

    private func row(_ action: LauncherAction, isHighlighted: Bool) -> some View {
        Button { select(action) } label: {
            HStack(spacing: 8) {
                Image(systemName: action.symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: action.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let key = action.key ?? (isHighlighted ? "↩" : nil), action.isEnabled {
                    LauncherKeycap(key: key)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isHighlighted ? theme.foreground.opacity(0.10) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.55)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}

struct LauncherMessage: View {
    let symbol: LauncherGlyph
    let title: String
    let detail: String?
    let isLoading: Bool

    init(symbol: LauncherGlyph, title: String, detail: String? = nil, isLoading: Bool = false) {
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
                    symbol.image()
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
