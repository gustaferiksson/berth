import GhosttyTerminal
import SwiftUI

enum SessionPane: String, CaseIterable {
    case changes, terminal

    var title: String {
        self == .changes ? "Changes" : "Terminal"
    }

    var action: AppAction {
        self == .changes ? .showChangesPane : .switchTerminal
    }

    static func available(isReviewEnabled: Bool) -> [Self] {
        isReviewEnabled ? allCases : [.terminal]
    }
}

struct PaneHost: View {
    let store: Store

    var body: some View {
        let isTerminal = store.sessionPane == .terminal
        ZStack {
            ReviewDiffColumn(store: store)
                .opacity(isTerminal ? 0 : 1)
                .allowsHitTesting(!isTerminal)
            TerminalPane(store: store)
                .opacity(isTerminal ? 1 : 0)
                .allowsHitTesting(isTerminal)
        }
        .environment(store)
        .environment(\.ghosttyTheme, store.theme)
    }
}

struct PaneMenu: View {
    let store: Store
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false

    var body: some View {
        Menu("Add Pane", systemImage: "plus") {
            ForEach(SessionPane.available(isReviewEnabled: isReviewEnabled), id: \.self) { pane in
                Button(pane.title, systemImage: pane.action.symbol) {
                    if pane == .terminal { store.showTerminalPane() } else { store.showChangesPane() }
                }
                .keyboardShortcut(pane.action.shortcut)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add Pane")
    }
}

// Owned shells must start while the column is collapsed (its view then leaves the window), so they float over the split instead of living in the column.
struct PaneTerminals: View {
    static let stripHeight = 33.0

    let store: Store
    let column: CGRect
    @State private var size = CGSize.zero

    var body: some View {
        let shown = store.sessionPane == .terminal && !store.isHarborShown ? store.sessionTab.flatMap { store.paneTerminal(of: $0.id) } : nil
        let area = column.isEmpty ? CGRect(origin: .zero, size: size) : CGRect(x: column.minX, y: column.minY + Self.stripHeight, width: column.width, height: max(column.height - Self.stripHeight, 1))
        ZStack(alignment: .topLeading) {
            ZStack {
                ForEach(store.tabs.filter { $0.parentTabID != nil }) { tab in
                    let isShown = tab.id == shown?.id
                    TerminalSurfaceView(context: tab.terminal)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .opacity(isShown ? 1 : 0)
                        .allowsHitTesting(isShown)
                        .onChange(of: isShown, initial: true) { tab.terminal.isSurfaceVisible = isShown }
                        .background { SelectsOnFocus(store: store, id: tab.id, terminal: tab.terminal) }
                }
            }
            .frame(width: area.width, height: area.height)
            .overlay(alignment: .topTrailing) {
                if store.isSearchingPaneTerminal {
                    TerminalFindBar()
                        .padding(12)
                }
            }
            .padding(.leading, area.minX)
            .padding(.top, area.minY)
            #if DEBUG
            if Snapshot.showsPaneMenu, !column.isEmpty {
                PaneMenuSnapshot()
                    .padding(.leading, column.maxX - 208)
                    .padding(.top, column.minY + 30)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .environment(store)
        .environment(\.ghosttyTheme, store.theme)
    }
}

private struct TerminalPane: View {
    let store: Store

    var body: some View {
        let session = store.sessionTab
        let shown = store.sessionPane == .terminal && !store.isHarborShown ? session.flatMap { store.paneTerminal(of: $0.id) } : nil
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(session.map { session in store.tabs.filter { $0.parentTabID == session.id } } ?? []) { tab in
                            PaneTerminalTab(tab: tab, terminal: tab.terminal, isSelected: tab.id == shown?.id)
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                Button("New Terminal", systemImage: "plus.rectangle") {
                    if let session { store.newTerminal(for: session.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Terminal")
                PaneMenu(store: store)
                    .padding(.trailing, 10)
            }
            .foregroundStyle(store.theme.foreground.opacity(0.6))
            .frame(height: 32)
            Divider()
            Color.clear
        }
        .background(store.theme.background ?? Color(nsColor: .textBackgroundColor))
        .overlay { CardBorder() }
    }
}

private struct PaneTerminalTab: View {
    let tab: Tab
    @ObservedObject var terminal: TerminalViewState
    let isSelected: Bool
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.terminal")
                .font(.caption)
                .accessibilityHidden(true)
            Text(tab.title(terminalTitle: terminal.title, sessionTitle: nil))
                .lineLimit(1)
            Button("Close Terminal", systemImage: "xmark") { store.close(tab.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .font(.callout)
        .foregroundStyle(theme.foreground.opacity(isSelected ? 1 : 0.6))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(theme.foreground.opacity(isSelected ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { store.activate(.tab(tab.id)) }
        .help((tab.folder as NSString).abbreviatingWithTildeInPath)
    }
}

struct SelectsOnFocus: View {
    let store: Store
    let id: Tab.ID
    @ObservedObject var terminal: TerminalViewState

    var body: some View {
        Color.clear
            .onChange(of: terminal.isFocused) {
                if terminal.isFocused, store.selectedTabID != id { store.selectedTabID = id }
            }
    }
}

#if DEBUG
// An NSMenu popup never renders offscreen, so snapshots draw the + menu's items in place.
private struct PaneMenuSnapshot: View {
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SessionPane.available(isReviewEnabled: isReviewEnabled), id: \.self) { pane in
                let keys = pane.action.shortcut.map { shortcut in
                    [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined() + String(shortcut.key.character).uppercased()
                } ?? ""
                HStack(spacing: 8) {
                    Image(systemName: pane.action.symbol)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(pane.title)
                    Spacer(minLength: 24)
                    Text(keys)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .onAppear { print("pane menu item \(pane.title) \(keys)") }
            }
        }
        .font(.body)
        .padding(5)
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 8))
        .shadow(radius: 8, y: 2)
    }
}
#endif
