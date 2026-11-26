import BerthCore
import SwiftUI

struct ConversationWelcome: View {
    let folderName: String
    let harness: Harness
    let fillDraft: (String) -> Void

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 5) {
                Image(harness.asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(theme.foreground)
                    .padding(.bottom, 5)
                    .accessibilityHidden(true)
                Text(verbatim: folderName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(harness.name)
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
            }
            .allowsHitTesting(false)

            if harness.supports(.modelEffortMenu) {
                suggestions
            }

            ViewThatFits(in: .horizontal) {
                hints
                EmptyView()
            }
            .font(.caption)
            .foregroundStyle(theme.secondary)
            .allowsHitTesting(false)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .frame(maxWidth: 560)
    }

    private var hints: some View {
        HStack(spacing: 12) {
            hint("/", "commands")
            if harness.supports(.bashMode) {
                hint("!", "shell")
            }
            hint("@", "files")
            if harness.supports(.modelEffortMenu) {
                Text("Drop images")
            }
        }
        .fixedSize()
    }

    private var suggestions: some View {
        let summarize = chip("Summarize this project")
        let fix = chip("Find and fix a bug")
        let review = chip("Review recent changes")

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summarize
                fix
                review
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    summarize
                    fix
                }
                review
            }
            VStack(spacing: 8) {
                summarize
                fix
                review
            }
        }
    }

    private func chip(_ prompt: String) -> some View {
        Button { fillDraft(prompt) } label: {
            Text(prompt)
                .font(.callout)
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: key)
                .monospaced()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 3))
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }
}
