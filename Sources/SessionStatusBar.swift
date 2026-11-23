import BerthCore
import SwiftUI

struct SessionStatusBar: View {
    let model: ConversationModel
    let tab: Tab
    let harness: Harness
    let isShell: Bool
    let isWorking: Bool
    let isWaiting: Bool

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @State private var summary: ReviewBranchSummary?

    var body: some View {
        let context = model.context
        let live = tab.sessionID.flatMap { store.liveBySession[$0] }

        HStack(spacing: 14) {
            HStack(spacing: 14) {
                if isShell {
                    Label("bash mode", systemImage: "terminal")
                        .foregroundStyle(theme.shellAttached)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Label(URL(filePath: tab.folder).lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .help(tab.folder)
                if let summary {
                    HStack(spacing: 6) {
                        Label(summary.branch, systemImage: "arrow.triangle.branch")
                            .foregroundStyle(theme.branch)
                            .lineLimit(1)
                        if summary.ahead > 0 { Text(verbatim: "↑\(summary.ahead)").monospacedDigit().foregroundStyle(.green).layoutPriority(1) }
                        if summary.behind > 0 { Text(verbatim: "↓\(summary.behind)").monospacedDigit().foregroundStyle(.orange).layoutPriority(1) }
                    }
                    .help("\(summary.branch), \(summary.ahead) ahead and \(summary.behind) behind")
                }
                if let mode = model.permissionMode.map(PermissionModeStyle.of) {
                    PermissionModeButton(style: mode, isEnabled: harness.supports(.permissionModes) && live?.status != "waiting", cycle: cycle)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if let context, let tokens = context.tokens, let window = context.window, window > 0 {
                    ContextButton(context: SessionContext(model: context.model, tokens: tokens, window: window), arrowEdge: .top)
                        .buttonStyle(.plain)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let context {
                SessionModelMenu(model: model, harness: harness, context: context, isWorking: isWorking, isWaiting: isWaiting)
                    .layoutPriority(1)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
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

private struct SessionModelMenu: View {
    let model: ConversationModel
    let harness: Harness
    let context: RemoteContext
    let isWorking: Bool
    let isWaiting: Bool

    @Environment(\.ghosttyTheme) private var theme
    @State private var showsContext = false

    var body: some View {
        Group {
            if harness.supports(.modelEffortMenu) {
                modelMenu
            } else {
                Button { showsContext = true } label: {
                    HStack(spacing: 6) {
                        Text(modelName(context.model))
                            .foregroundStyle(theme.foreground)
                        if let effort = context.effort {
                            Text(effort.capitalized)
                        }
                        if let tokens = context.tokens, let window = context.window, window > 0 {
                            Text((Double(tokens) / Double(window)).formatted(.wholePercent))
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Context")
            }
        }
        .accessibilityLabel("Model and effort")
        .popover(isPresented: $showsContext, arrowEdge: .top) { contextPopover }
    }

    private var modelMenu: some View {
        let canChange = !isWorking && !isWaiting && !model.isSending
        let modelChoice = Binding<ModelChoice?> {
            model.pickedModel ?? ModelChoice(modelID: context.model)
        } set: { choice in
            guard let choice else { return }

            Task { await model.choose(.model(choice)) }
        }
        let effortChoice = Binding<EffortLevel?> {
            model.pickedEffort ?? context.effort.flatMap(EffortLevel.init)
        } set: { level in
            guard let level else { return }

            Task { await model.choose(.effort(level)) }
        }
        let modelTitle = model.pickedModel.flatMap { $0 == .default ? nil : $0.title } ?? modelName(context.model)

        return Menu {
            Section("Model") {
                Picker("Model", selection: modelChoice) {
                    ForEach(ModelChoice.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(!canChange)
            Section("Effort") {
                Picker("Effort", selection: effortChoice) {
                    ForEach(EffortLevel.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(!canChange || context.effort == nil && model.pickedEffort == nil)
            Divider()
            Button("Context", systemImage: "chart.pie") { showsContext = true }
            Text(canChange ? "Changes apply to this session only" : "Available while \(harness.name) is idle")
        } label: {
            Text("\(Text(modelTitle).foregroundStyle(theme.foreground)) \(Text(effortChoice.wrappedValue?.title ?? "").foregroundStyle(theme.secondary))")
                .lineLimit(1)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Model, effort and context")
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(modelName(context.model))
                .font(.headline)
            if !harness.supports(.modelEffortMenu), let effort = context.effort {
                Text(effort.capitalized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let tokens = context.tokens, let window = context.window, window > 0 {
                ProgressView(value: min(Double(tokens) / Double(window), 1))
                Text("\(tokenCount(tokens)) of \(tokenCount(window)) tokens, \((Double(tokens) / Double(window)).formatted(.wholePercent)) full")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Context size unknown until \(harness.name) replies")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }

    private func modelName(_ model: String) -> String {
        guard harness.supports(.modelEffortMenu) else { return model }

        let parts = model.split(separator: "-").filter { $0 != "claude" && !($0.count == 8 && Int($0) != nil) }
        let name = parts.filter { Int($0) == nil }.map(\.capitalized).joined(separator: " ")
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        return name + (version.isEmpty ? "" : " " + version)
    }
}
