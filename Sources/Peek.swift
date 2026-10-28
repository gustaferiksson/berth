import BerthCore
import SwiftUI

struct Peek: View {
    let session: SessionSummary
    let messages: [PeekMessage]?
    let pullRequestState: PullRequestState?
    let isOpen: Bool
    let handleKey: (KeyEquivalent) -> KeyPress.Result
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            conversation
            Divider()
            Text(isOpen ? "↩ Show · Space Close" : "↩ Resume · Space Close")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .frame(width: 400)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(keys: [.downArrow, .upArrow, .return, .space, .escape]) { handleKey($0.key) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(URL(filePath: session.cwd).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if let pullRequest = session.pullRequest {
                    PullRequestTag(link: pullRequest, state: pullRequestState)
                }
                if let branch = session.branch {
                    BranchText(branch: branch)
                }
                Spacer(minLength: 0)
                Text(session.lastActivity, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if let messages, !messages.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        row(message)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Group {
                if messages == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No recent messages").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
    }

    @ViewBuilder
    private func row(_ message: PeekMessage) -> some View {
        if message.kind == .tools {
            Label(message.text, systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            let markdown = (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text)
            Text(markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(message.kind == .prompt ? 8 : 0)
                .background(message.kind == .prompt ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        }
    }
}
