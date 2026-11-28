import SwiftUI

struct PermissionModeChip: View {
    let mode: String
    let isEnabled: Bool
    let cycle: () -> Void

    @State private var cycles = 0

    var body: some View {
        let style = Style.of(mode)

        Button {
            cycles += 1
            cycle()
        } label: {
            Label(style.title, systemImage: style.symbol)
                .font(.subheadline)
                .foregroundStyle(style.color)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: ComposerLayout.controlSize)
                .background(style.color.opacity(0.14), in: .capsule)
                .frame(minWidth: ComposerLayout.hitSize)
                .frame(height: ComposerLayout.hitSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .sensoryFeedback(.selection, trigger: cycles)
        .accessibilityLabel("Permission mode, \(style.title)")
        .accessibilityHint("Switches to the next mode")
    }
}

private struct Style {
    let title: String
    let symbol: String
    let color: Color

    private static let known = [
        "auto": Self(title: "Auto", symbol: "chevron.forward.2", color: .orange),
        "plan": Self(title: "Plan", symbol: "pause", color: .teal),
        "acceptEdits": Self(title: "Accept edits", symbol: "chevron.forward.2", color: .green),
        "bypassPermissions": Self(title: "Bypass", symbol: "exclamationmark.shield", color: .red),
        "dontAsk": Self(title: "Don’t ask", symbol: "chevron.forward.2", color: .secondary),
    ]

    static func of(_ mode: String) -> Self {
        known[mode] ?? Self(title: "Ask", symbol: "checkmark.shield", color: .secondary)
    }
}
