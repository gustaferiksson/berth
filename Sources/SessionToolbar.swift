import BerthCore
import SwiftUI

extension Store {
    var showsSessionToolbar: Bool {
        !isHarborShown && (selectedSessionID != nil || shownPane == .browser || canShowTasksPane)
    }
}

// A toolbar-less inspector gets no tracking separator, so the window's trailing items would sit over it.
struct SessionToolbar: ToolbarContent {
    let store: Store

    var body: some ToolbarContent {
        if store.showsSessionToolbar, let sessionID = store.selectedSessionID, !store.selectedStatusBarIsReachable {
            ToolbarItem(placement: .primaryAction) { ContextButton(context: store.sessionsByID[sessionID]?.context) }
        }
        if store.canShowConversation {
            ToolbarItem(placement: .primaryAction) { ConversationButton() }
        }
    }
}

// Declared in the detail or the pane sidebar by mode; a shared id moved one live item between hosts and stranded it (#441).
struct ChangesToolbar: ToolbarContent {
    let store: Store
    let host: String
    let flips: Int
    let isRebuilding: Bool

    var body: some ToolbarContent {
        if store.showsSessionToolbar, !isRebuilding {
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItem(id: "session-mode-switcher-\(host)-\(flips)", placement: .primaryAction) { ModeSwitcher(store: store, itemID: "\(host)-\(flips)") }
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
