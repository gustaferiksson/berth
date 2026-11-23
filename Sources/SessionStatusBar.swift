import BerthCore
import SwiftUI

struct SessionStatusBar: View {
    let model: ConversationModel
    let tab: Tab
    let harness: Harness
    let isWorking: Bool

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @State private var summary: ReviewBranchSummary?

    var body: some View {
        let context = model.context.flatMap { context -> SessionContext? in
            guard let tokens = context.tokens, context.window != nil else { return nil }

            return SessionContext(model: context.model, tokens: tokens, window: context.window)
        }
        let live = tab.sessionID.flatMap { store.liveBySession[$0] }

        HStack(spacing: 14) {
            Label(URL(filePath: tab.folder).lastPathComponent, systemImage: "folder")
                .lineLimit(1)
                .help(tab.folder)
            if let summary {
                HStack(spacing: 6) {
                    Label(summary.branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                    if summary.ahead > 0 { Text(verbatim: "↑\(summary.ahead)").monospacedDigit() }
                    if summary.behind > 0 { Text(verbatim: "↓\(summary.behind)").monospacedDigit() }
                }
                .help("\(summary.branch), \(summary.ahead) ahead and \(summary.behind) behind")
            }
            if let mode = model.permissionMode.map(PermissionModeStyle.of) {
                PermissionModeButton(style: mode, isEnabled: harness.supports(.permissionModes) && live?.status != "waiting", cycle: cycle)
            }
            Spacer(minLength: 12)
            if let context {
                ContextButton(context: context, arrowEdge: .top)
                    .buttonStyle(.plain)
            }
            ModeSegment()
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .foregroundStyle(theme.secondary)
        .padding(.horizontal, 16)
        .frame(height: 26)
        .task(id: isWorking) {
            while !Task.isCancelled {
                summary = await ReviewGit.branchSummary(in: tab.folder)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func cycle() {
        guard let sessionID = tab.sessionID else { return }

        _ = store.cycleMode(sessionID)
    }
}

private struct PermissionModeStyle {
    let title: String
    let symbol: String
    let color: KeyPath<GhosttyTheme, Color>

    private static let ask = Self(title: "Ask", symbol: "checkmark.shield", color: \.secondary)
    private static let known = [
        "auto": Self(title: "Auto", symbol: "chevron.forward.2", color: \.needsYou),
        "plan": Self(title: "Plan", symbol: "pause", color: \.branch),
        "acceptEdits": Self(title: "Accept edits", symbol: "chevron.forward.2", color: \.merged),
        "bypassPermissions": Self(title: "Bypass", symbol: "exclamationmark.shield", color: \.closed),
        "dontAsk": Self(title: "Don’t ask", symbol: "chevron.forward.2", color: \.secondary),
    ]

    static func of(_ mode: String) -> Self {
        known[mode] ?? ask
    }
}

private struct PermissionModeButton: View {
    let style: PermissionModeStyle
    let isEnabled: Bool
    let cycle: () -> Void
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let label = Label(style.title, systemImage: style.symbol).foregroundStyle(theme[keyPath: style.color])

        if isEnabled {
            Button(action: cycle) { label.contentShape(.rect) }
                .buttonStyle(.plain)
                .help("Cycle permission mode (⇧⇥)")
        } else {
            label
                .help("Permission mode")
        }
    }
}

private struct ModeSegment: View {
    @Environment(Store.self) private var store

    var body: some View {
        Picker("View", selection: Binding(get: { store.selectedShowsConversation }, set: store.setConversation)) {
            Label(AppAction.showTerminal.title, systemImage: AppAction.showTerminal.symbol).tag(false)
            Label(AppAction.showConversation.title, systemImage: AppAction.showConversation.symbol).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .fixedSize()
        .help("Show Terminal or Conversation (⌥⌘J)")
    }
}
