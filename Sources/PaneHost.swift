import GhosttyTerminal
import SwiftUI

enum SessionPane: String, CaseIterable {
    case changes, browser, terminal

    var title: String {
        rawValue.capitalized
    }

    var action: AppAction {
        if self == .terminal { return .switchTerminal }
        if self == .browser { return .showBrowser }
        return .showChangesPane
    }
}

struct PaneHost: View {
    let store: Store

    var body: some View {
        let isTerminal = store.sessionPane == .terminal
        ZStack {
            ReviewDiffColumn(store: store)
                .opacity(store.sessionPane == .changes ? 1 : 0)
                .allowsHitTesting(store.sessionPane == .changes)
            VStack(spacing: 0) {
                if let terminal = store.sessionTab.flatMap({ store.paneTerminal(of: $0.id) }) {
                    TerminalPathBar(tab: terminal, terminal: terminal.terminal)
                }
                Divider()
                Color.clear
            }
            .background(store.theme.background ?? Color(nsColor: .textBackgroundColor))
            .overlay { CardBorder() }
            .opacity(isTerminal ? 1 : 0)
            if store.sessionPane == .browser { BrowserPane(store: store) }
        }
        .environment(store)
        .environment(\.ghosttyTheme, store.theme)
    }
}

private struct TerminalPathBar: View {
    static let height = 22.0

    let tab: Tab
    @ObservedObject var terminal: TerminalViewState
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text((tab.folder as NSString).abbreviatingWithTildeInPath)
                .truncationMode(.head)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .accessibilityHidden(true)
            Image(systemName: "apple.terminal")
                .accessibilityHidden(true)
            Text(tab.title(terminalTitle: terminal.title, sessionTitle: nil))
                .foregroundStyle(theme.foreground)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(theme.foreground.opacity(0.6))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: Self.height)
    }
}

struct SessionPanel: View {
    @Environment(Store.self) private var store

    var body: some View {
        if store.sessionPane == .terminal {
            TerminalList()
        } else if store.sessionPane == .browser {
            BrowserTabList()
        } else {
            ReviewPanel()
        }
    }
}

struct ModeSwitcher: View {
    let store: Store
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false

    var body: some View {
        ControlGroup {
            ForEach(isReviewEnabled ? SessionPane.allCases : [.browser, .terminal], id: \.self) { mode in
                let keys = mode == .changes ? "⇧⌘D" : mode == .browser ? "⇧⌘B" : "⌘J"
                Toggle(mode.title, systemImage: mode.action.symbol, isOn: Binding(get: { store.shownPane == mode }, set: { isOn in
                    if !isOn { store.hideSessionPanel() } else if mode == .terminal { store.showTerminalPane() } else if mode == .browser { store.showBrowserPane() } else { store.showChangesPane() }
                }))
                .help("\(mode.title) (\(keys))")
            }
        }
        .labelStyle(.iconOnly)
    }
}

private struct TerminalList: View {
    @Environment(Store.self) private var store

    var body: some View {
        let session = store.sessionTab
        let shown = session.flatMap { store.paneTerminal(of: $0.id) }
        List {
            Section {
                ForEach(session.map { session in store.tabs.filter { $0.parentTabID == session.id } } ?? []) { tab in
                    TerminalListRow(tab: tab, terminal: tab.terminal, isSelected: tab.id == shown?.id)
                }
            } header: {
                HStack {
                    Text("Terminals")
                    Spacer()
                    Button("New Terminal", systemImage: "plus") {
                        if let session { store.newTerminal(for: session.id) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("New Terminal")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct TerminalListRow: View {
    let tab: Tab
    @ObservedObject var terminal: TerminalViewState
    let isSelected: Bool
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title(terminalTitle: terminal.title, sessionTitle: nil))
                    .lineLimit(1)
                Text((tab.folder as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            Button("Close Terminal", systemImage: "xmark") { store.close(tab.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(theme.foreground.opacity(isSelected ? 0.1 : 0), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture { store.activate(.tab(tab.id)) }
        .contextMenu {
            Button("Close Terminal") { store.close(tab.id) }
        }
    }
}

// Owned shells must start while the column is collapsed (its view then leaves the window), so they float over the split instead of living in the column.
struct PaneTerminals: View {
    let store: Store
    let column: CGRect
    @State private var size = CGSize.zero

    var body: some View {
        let shown = store.sessionPane == .terminal && !store.isHarborShown ? store.sessionTab.flatMap { store.paneTerminal(of: $0.id) } : nil
        let area = column.isEmpty ? CGRect(origin: .zero, size: size) : CGRect(x: column.minX, y: column.minY + TerminalPathBar.height + 1, width: column.width, height: max(column.height - TerminalPathBar.height - 1, 1))
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .environment(store)
        .environment(\.ghosttyTheme, store.theme)
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
