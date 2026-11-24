import BerthCore
import SwiftUI

struct ChangeSize: Equatable {
    let additions: Int
    let deletions: Int

    init(_ changes: ReviewChanges) {
        let size = changes.total ?? changes.uncommitted.reduce((additions: 0, deletions: 0)) { ($0.additions + ($1.additions ?? 0), $0.deletions + ($1.deletions ?? 0)) }
        additions = size.additions
        deletions = size.deletions
    }
}

extension Store {
    var showsSessionToolbar: Bool {
        !isHarborShown && selectedSessionID != nil
    }

    var selectedChangeSize: ChangeSize? {
        guard let sessionID = selectedSessionID else { return nil }

        let size = primaryReviewModel?.changes.map(ChangeSize.init) ?? changeSizes[sessionID]
        guard let size, size.additions + size.deletions > 0 else { return nil }

        return size
    }

    // The panel's model keeps its own changes live; this covers a session whose panel was never shown.
    func trackChangeSize(sessionID: String, folder: String) async {
        while !Task.isCancelled {
            if primaryReviewModel?.changes == nil {
                let picks = UserDefaults.standard.dictionary(forKey: ReviewModel.baseBranchesKey) as? [String: [String: String]] ?? [:]
                let changes = try? await ReviewGit.changes(in: folder) { root, branch in (picks[root]?[branch], nil) }
                changeSizes[sessionID] = changes.map(ChangeSize.init)
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}

// A toolbar-less inspector gets no tracking separator, so the window's trailing items would sit over it.
struct SessionToolbar: ToolbarContent {
    let store: Store
    let isReviewEnabled: Bool

    var body: some ToolbarContent {
        if store.showsSessionToolbar, let sessionID = store.selectedSessionID, !store.selectedStatusBarIsReachable {
            ToolbarItem(placement: .primaryAction) { ContextButton(context: store.sessionsByID[sessionID]?.context) }
        }
        if store.canShowConversation {
            ToolbarItem(placement: .primaryAction) { ConversationButton() }
        }
    }
}

struct ChangesToolbar: ToolbarContent {
    let store: Store
    let isReviewEnabled: Bool

    var body: some ToolbarContent {
        if store.showsSessionToolbar, let sessionID = store.selectedSessionID {
            let pullRequests = store.sessionsByID[sessionID].map { store.pullRequests(of: $0) } ?? []
            if isReviewEnabled || !pullRequests.isEmpty {
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    if let first = pullRequests.first { PullRequestButton(pullRequest: first.pullRequest) }
                    if isReviewEnabled { ChangesToggle(store: store) }
                }
            }
        }
    }
}

private struct ConversationButton: View {
    @Environment(Store.self) private var store

    var body: some View {
        let action = store.selectedConversationIsVisible ? AppAction.showTerminal : .showConversation

        Button { action.perform(on: store) } label: {
            Image(systemName: action.symbol)
        }
        .accessibilityLabel(action.title)
        .help("\(action.title) (⌥⌘J)")
    }
}

private struct PullRequestButton: View {
    let pullRequest: PullRequest
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(pullRequest.url) } label: {
            Label { Text(verbatim: "#\(pullRequest.number)") } icon: { OcticonImage(Octicon(pullRequest.state)) }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(pullRequest.state.color(in: theme))
        }
        .help("Open pull request #\(String(pullRequest.number))")
    }
}

private struct ChangesToggle: View {
    let store: Store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let isShown = AppAction.hideChanges.isAvailable(in: store)
        let action = isShown ? AppAction.hideChanges : .showChanges
        Button { action.perform(on: store) } label: {
            if let size = store.selectedChangeSize {
                HStack(spacing: 5) {
                    Text(verbatim: "+\(size.additions)").foregroundStyle(theme.working)
                    Text(verbatim: "−\(size.deletions)").foregroundStyle(theme.closed)
                }
                .monospacedDigit()
            } else {
                Image(systemName: action.symbol)
            }
        }
        .accessibilityLabel(action.title)
        .help("\(action.title) (⇧⌘R)")
    }
}

struct ContextButton: View {
    let context: SessionContext?
    var arrowEdge = Edge.bottom
    @Environment(\.ghosttyTheme) private var theme
    @State private var isShown = false

    var body: some View {
        let fill = context.flatMap { context in context.window.map { Double(context.tokens) / Double($0) } }
        let percent = fill?.formatted(.wholePercent)
        Button { isShown.toggle() } label: {
            HStack(spacing: 5) {
                if let context, let window = context.window {
                    ContextRing(context: context, window: window)
                        .frame(width: 14)
                } else {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 2)
                        .frame(width: 13, height: 13)
                        .accessibilityLabel("Context unknown")
                }
                if let percent { Text(percent).monospacedDigit() }
            }
        }
        .help("Context")
        .popover(isPresented: $isShown, arrowEdge: arrowEdge) {
            VStack(alignment: .leading, spacing: 6) {
                Text(context.map { $0.modelName ?? $0.model } ?? "Context")
                    .font(.headline)
                if let context, let window = context.window, let fill, let percent {
                    ProgressView(value: min(fill, 1))
                        .tint(fill >= 0.9 ? theme.closed : fill >= 0.7 ? theme.needsYou : nil)
                    Text("\(tokenCount(context.tokens)) of \(tokenCount(window)) tokens, \(percent) full")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Context size unknown until Claude replies")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(width: 260, alignment: .leading)
        }
    }
}
