import BerthCore
import SwiftUI

struct ConversationApprovalCard: View {
    let approval: PendingApproval
    let since: Date?
    let answer: (RemoteKey) -> Void
    let deny: () -> Void
    let declineWithMessage: () -> Void
    let showTerminal: () -> Void

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(isQuestion ? "Question" : "Needs Approval", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.needsYou)
                Spacer()
                if let since {
                    ConversationElapsed(since: since)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Menu("More", systemImage: "ellipsis") {
                    Button("Deny with Message…", systemImage: "text.bubble", action: declineWithMessage)
                    Button("Show Terminal", systemImage: "apple.terminal", action: showTerminal)
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(theme.needsYou.opacity(0.1)), in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isQuestion ? "Question from Claude" : "Approval needed")
    }

    private var isQuestion: Bool {
        if case .question = approval { true } else { false }
    }

    @ViewBuilder private var content: some View {
        switch approval {
        case let .permission(tool, target, detail, edit):
            Text(verbatim: tool)
                .font(.headline)
            if let detail {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let edit {
                Text(verbatim: target)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ScrollView {
                    ConversationDiff(rows: ToolDiff.rows(old: edit.old, new: edit.new), language: target, isExpanded: true)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ConversationCodeBlock(text: target, syntax: tool == "Bash" ? "bash" : nil, maxHeight: 160)
            }
            buttons(allow: "Allow", deny: "Deny")

        case let .question(question, options):
            Text(verbatim: question)
                .font(.headline)
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(options.enumerated(), id: \.offset) { index, option in
                        Button {
                            answer(RemoteKey(rawValue: "digit\(index + 1)") ?? .digit1)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(verbatim: "\(index + 1)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: option.label)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let detail = option.detail {
                                        Text(verbatim: detail)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 10))
                        .help("Choose \(option.label) (\(index + 1))")
                    }
                }
            }
            HStack {
                Spacer()
                Button(action: deny) {
                    keyLabel("Dismiss", "⎋")
                }
                .buttonStyle(.borderless)
                .help("Dismiss (⎋)")
            }

        case let .plan(plan):
            Text("Ready to start?")
                .font(.headline)
            ScrollView {
                ConversationMarkdown(text: plan)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            buttons(allow: "Approve Plan", deny: "Keep Planning")

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for details")
                    .foregroundStyle(.secondary)
            }

        case .unrepresentable:
            EmptyView()
        }
    }

    private func buttons(allow: String, deny title: String) -> some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: deny) {
                keyLabel(title, "⎋")
            }
            .buttonStyle(.bordered)
            .help("\(title) (⎋)")
            Button {
                answer(.digit1)
            } label: {
                keyLabel(allow, "↩")
            }
            .buttonStyle(.borderedProminent)
            .help("\(allow) (↩)")
        }
        .controlSize(.large)
    }

    private func keyLabel(_ title: String, _ key: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Text(verbatim: key)
                .opacity(0.6)
                .accessibilityHidden(true)
        }
    }
}
