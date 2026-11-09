import BerthCore
import SwiftUI

enum AppAction: Hashable {
    case commandPalette, newSession, searchSessions, newTerminal, switchTerminal, clearTerminal, archiveCurrentSession, flagCurrentSession, unflagCurrentSession
    case groupBy(GroupingMode)
    case newGroup, collapseAllGroups, expandAllGroups, showStats, harbor, reviewChanges, settings, checkForUpdates

    static let palette: [AppAction] = [.newSession, .searchSessions, .newTerminal, .switchTerminal, .clearTerminal, .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession]
        + GroupingMode.allCases.map(AppAction.groupBy)
        + [.newGroup, .collapseAllGroups, .expandAllGroups, .showStats, .harbor, .reviewChanges, .settings, .checkForUpdates]
    static let routedPastTerminal = ([.commandPalette] + palette).filter { $0.shortcut != nil }

    var title: String {
        switch self {
        case .commandPalette: "Command Palette…"
        case .newSession: "New Session…"
        case .searchSessions: "Search Sessions…"
        case .newTerminal: "New Terminal"
        case .switchTerminal: "Switch Terminal / Claude"
        case .clearTerminal: "Clear Terminal"
        case .archiveCurrentSession: "Archive Current Session"
        case .flagCurrentSession: "Flag Current Session"
        case .unflagCurrentSession: "Unflag Current Session"
        case let .groupBy(mode): "Group By \(mode.title)"
        case .newGroup: "New Group…"
        case .collapseAllGroups: "Collapse All Groups"
        case .expandAllGroups: "Expand All Groups"
        case .showStats: "Show Stats"
        case .harbor: "Harbor"
        case .reviewChanges: "Review Changes"
        case .settings: "Settings…"
        case .checkForUpdates: "Check for Updates…"
        }
    }

    var keywords: String {
        switch self {
        case .newSession: "claude start folder"
        case .searchSessions: "find transcripts"
        case .newTerminal: "shell tab"
        case .switchTerminal: "shell toggle jump"
        case .clearTerminal: "screen scrollback"
        case .flagCurrentSession, .unflagCurrentSession: "follow up mark"
        case .groupBy: "sidebar"
        case .showStats: "usage tokens charts activity"
        case .harbor: "ambient boats piers overview"
        case .reviewChanges: "diff branch changes comments"
        case .settings: "preferences"
        case .checkForUpdates: "update version release"
        default: ""
        }
    }

    var symbol: String {
        switch self {
        case .commandPalette: "command"
        case .newSession: "plus.bubble"
        case .searchSessions: "magnifyingglass"
        case .newTerminal: "plus.rectangle"
        case .switchTerminal: "apple.terminal"
        case .clearTerminal: "eraser"
        case .archiveCurrentSession: "archivebox"
        case .flagCurrentSession: "flag"
        case .unflagCurrentSession: "flag.slash"
        case .groupBy: "square.grid.3x1.below.line.grid.1x2"
        case .newGroup: "folder.badge.plus"
        case .collapseAllGroups: "rectangle.compress.vertical"
        case .expandAllGroups: "rectangle.expand.vertical"
        case .showStats: "chart.bar.xaxis"
        case .harbor: "sailboat"
        case .reviewChanges: "plus.forwardslash.minus"
        case .settings: "gear"
        case .checkForUpdates: "arrow.down.circle"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .commandPalette: KeyboardShortcut("k")
        case .newSession: KeyboardShortcut("n")
        case .searchSessions: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .newTerminal: KeyboardShortcut("t")
        case .switchTerminal: KeyboardShortcut("j")
        case .clearTerminal: KeyboardShortcut("k", modifiers: [.command, .option])
        case let .groupBy(mode): KeyboardShortcut(KeyEquivalent(Character("\((GroupingMode.allCases.firstIndex(of: mode) ?? 0) + 1)")), modifiers: [.control, .command])
        case .showStats: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .reviewChanges: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .settings: KeyboardShortcut(",")
        default: nil
        }
    }

    func isAvailable(in store: Store) -> Bool {
        switch self {
        case .clearTerminal: store.focusedTerminal != nil
        case .archiveCurrentSession: if case .session = store.selection { true } else { false }
        case .flagCurrentSession: if case let .session(id) = store.selection { !store.flaggedIDs.contains(id) } else { false }
        case .unflagCurrentSession: if case let .session(id) = store.selection { store.flaggedIDs.contains(id) } else { false }
        case let .groupBy(mode): store.groupingMode != mode
        case .reviewChanges: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.tabs.first { $0.id == store.selectedTabID }.map { $0.kind == .claude && $0.sessionID != nil } == true
        default: true
        }
    }

    func perform(on store: Store) {
        switch self {
        case .commandPalette: store.launcherMode = store.launcherMode == .palette ? nil : .palette
        case .newSession: store.launcherMode = .newSession
        case .searchSessions: store.launcherMode = .search
        case .newTerminal: store.newTerminal()
        case .switchTerminal: store.switchTerminal()
        case .clearTerminal: store.focusedTerminal?.performBindingAction("clear_screen")
        case .archiveCurrentSession: if case let .session(id) = store.selection { store.archive(id) }
        case .flagCurrentSession: if case let .session(id) = store.selection { store.flag(id) }
        case .unflagCurrentSession: if case let .session(id) = store.selection { store.unflag(id) }
        case let .groupBy(mode): store.groupingMode = mode
        case .newGroup: store.editingGroup = CustomGroup(name: "", rules: [])
        case .collapseAllGroups: store.setGroupsExpanded(false)
        case .expandAllGroups: store.setGroupsExpanded(true)
        case .showStats: store.isStatsRequested = true
        case .harbor: store.isHarborShown.toggle()
        case .reviewChanges: store.toggleReview()
        case .settings: store.isSettingsRequested = true
        case .checkForUpdates: store.updater.check(.manual)
        }
    }

    func menuButton(_ store: Store) -> some View {
        Button(title) { perform(on: store) }
            .keyboardShortcut(shortcut)
    }
}
