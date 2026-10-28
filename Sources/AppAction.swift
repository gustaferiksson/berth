import BerthCore
import SwiftUI

enum AppAction: Hashable {
    case commandPalette, newSession, searchSessions, newTerminal, toggleTerminalPanel, clearTerminal, archiveCurrentSession
    case groupBy(GroupingMode)
    case newGroup, collapseAllGroups, expandAllGroups, showStats, settings

    static let palette: [AppAction] = [.newSession, .searchSessions, .newTerminal, .toggleTerminalPanel, .clearTerminal, .archiveCurrentSession]
        + GroupingMode.allCases.map(AppAction.groupBy)
        + [.newGroup, .collapseAllGroups, .expandAllGroups, .showStats, .settings]
    static let routedPastTerminal: [AppAction] = [.commandPalette, .toggleTerminalPanel, .newTerminal, .clearTerminal]

    var title: String {
        switch self {
        case .commandPalette: "Command Palette…"
        case .newSession: "New Session…"
        case .searchSessions: "Search Sessions…"
        case .newTerminal: "New Terminal"
        case .toggleTerminalPanel: "Toggle Terminal Panel"
        case .clearTerminal: "Clear Terminal"
        case .archiveCurrentSession: "Archive Current Session"
        case let .groupBy(mode): "Group By \(mode.title)"
        case .newGroup: "New Group…"
        case .collapseAllGroups: "Collapse All Groups"
        case .expandAllGroups: "Expand All Groups"
        case .showStats: "Show Stats"
        case .settings: "Settings…"
        }
    }

    var keywords: String {
        switch self {
        case .newSession: "claude start folder"
        case .searchSessions: "find transcripts"
        case .newTerminal: "shell tab"
        case .toggleTerminalPanel: "show hide shell"
        case .clearTerminal: "screen scrollback"
        case .groupBy: "sidebar"
        case .showStats: "usage tokens charts activity"
        case .settings: "preferences"
        default: ""
        }
    }

    var symbol: String {
        switch self {
        case .commandPalette: "command"
        case .newSession: "plus.bubble"
        case .searchSessions: "magnifyingglass"
        case .newTerminal: "plus.rectangle"
        case .toggleTerminalPanel: "apple.terminal"
        case .clearTerminal: "eraser"
        case .archiveCurrentSession: "archivebox"
        case .groupBy: "square.grid.3x1.below.line.grid.1x2"
        case .newGroup: "folder.badge.plus"
        case .collapseAllGroups: "rectangle.compress.vertical"
        case .expandAllGroups: "rectangle.expand.vertical"
        case .showStats: "chart.bar.xaxis"
        case .settings: "gear"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .commandPalette: KeyboardShortcut("k")
        case .newSession: KeyboardShortcut("n")
        case .searchSessions: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .newTerminal: KeyboardShortcut("t")
        case .toggleTerminalPanel: KeyboardShortcut("j")
        case .clearTerminal: KeyboardShortcut("k", modifiers: [.command, .option])
        case let .groupBy(mode): KeyboardShortcut(KeyEquivalent(Character("\((GroupingMode.allCases.firstIndex(of: mode) ?? 0) + 1)")), modifiers: [.control, .command])
        case .showStats: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .settings: KeyboardShortcut(",")
        default: nil
        }
    }

    func isAvailable(in store: Store) -> Bool {
        switch self {
        case .clearTerminal: store.focusedTerminal != nil
        case .archiveCurrentSession: if case .session = store.selection { true } else { false }
        case let .groupBy(mode): store.groupingMode != mode
        default: true
        }
    }

    func perform(on store: Store) {
        switch self {
        case .commandPalette: store.launcherMode = store.launcherMode == .palette ? nil : .palette
        case .newSession: store.launcherMode = .newSession
        case .searchSessions: store.launcherMode = .search
        case .newTerminal: store.openShell(cwd: store.currentCwd)
        case .toggleTerminalPanel: store.toggleTerminalPanel()
        case .clearTerminal: store.focusedTerminal?.performBindingAction("clear_screen")
        case .archiveCurrentSession: if case let .session(id) = store.selection { store.archive(id) }
        case let .groupBy(mode): store.groupingMode = mode
        case .newGroup: store.editingGroup = CustomGroup(name: "", rules: [])
        case .collapseAllGroups: store.setGroupsExpanded(false)
        case .expandAllGroups: store.setGroupsExpanded(true)
        case .showStats: store.isStatsRequested = true
        case .settings: break
        }
    }

    func menuButton(_ store: Store) -> some View {
        Button(title) { perform(on: store) }
            .keyboardShortcut(shortcut)
    }
}
