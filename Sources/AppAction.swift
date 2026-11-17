import BerthCore
import SwiftUI

enum AppAction: Hashable {
    case commandPalette, newSession, searchSessions, newTerminal, switchTerminal, findInTerminal, clearTerminal, archiveCurrentSession, flagCurrentSession, unflagCurrentSession
    case groupBy(GroupingMode)
    case newGroup, collapseAllGroups, expandAllGroups, showStats, harbor, showChanges, hideChanges, settings, checkForUpdates

    static let palette: [AppAction] = [.newSession, .searchSessions, .newTerminal, .switchTerminal, .findInTerminal, .clearTerminal, .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession]
        + GroupingMode.allCases.map(AppAction.groupBy)
        + [.newGroup, .collapseAllGroups, .expandAllGroups, .showStats, .harbor, .showChanges, .hideChanges, .settings, .checkForUpdates]
    static let routedPastTerminal = ([.commandPalette] + palette).filter { $0.shortcut != nil }

    var title: String {
        switch self {
        case .commandPalette: "Command Palette…"
        case .newSession: "New Session…"
        case .searchSessions: "Search Sessions…"
        case .newTerminal: "New Terminal"
        case .switchTerminal: "Switch Terminal / Claude"
        case .findInTerminal: "Find…"
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
        case .showChanges: "Show Changes"
        case .hideChanges: "Hide Changes"
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
        case .findInTerminal: "search terminal scrollback text"
        case .clearTerminal: "screen scrollback"
        case .flagCurrentSession, .unflagCurrentSession: "follow up mark"
        case .groupBy: "sidebar"
        case .showStats: "usage tokens charts activity"
        case .harbor: "ambient boats piers overview"
        case .showChanges, .hideChanges: "review diff branch changes comments panel"
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
        case .findInTerminal: "text.magnifyingglass"
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
        case .showChanges, .hideChanges: "plus.forwardslash.minus"
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
        case .findInTerminal: KeyboardShortcut("f")
        case .clearTerminal: KeyboardShortcut("k", modifiers: [.command, .option])
        case let .groupBy(mode): KeyboardShortcut(KeyEquivalent(Character("\((GroupingMode.allCases.firstIndex(of: mode) ?? 0) + 1)")), modifiers: [.control, .command])
        case .showStats: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .showChanges, .hideChanges: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .settings: KeyboardShortcut(",")
        default: nil
        }
    }

    func isAvailable(in store: Store) -> Bool {
        switch self {
        case .findInTerminal: store.focusedTerminal != nil && !store.isHarborShown
        case .clearTerminal: store.focusedTerminal != nil
        case .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession: !sessionIDs(in: store).isEmpty
        case let .groupBy(mode): store.groupingMode != mode
        case .showChanges: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && (!store.showsReviewPanel || store.isHarborShown)
        case .hideChanges: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.showsReviewPanel && !store.isHarborShown
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
        case .findInTerminal: if isAvailable(in: store) { store.focusedTerminal?.performBindingAction("start_search") }
        case .clearTerminal: store.focusedTerminal?.performBindingAction("clear_screen")
        case .archiveCurrentSession: for id in sessionIDs(in: store) { store.archive(id) }
        case .flagCurrentSession: for id in sessionIDs(in: store) { store.flag(id) }
        case .unflagCurrentSession: for id in sessionIDs(in: store) { store.unflag(id) }
        case let .groupBy(mode): store.groupingMode = mode
        case .newGroup: store.editingGroup = CustomGroup(name: "", rules: [])
        case .collapseAllGroups: store.setGroupsExpanded(false)
        case .expandAllGroups: store.setGroupsExpanded(true)
        case .showStats: store.isStatsRequested = true
        case .harbor: store.isHarborShown.toggle()
        case .showChanges:
            store.showsReviewPanel = true
            store.isHarborShown = false
        case .hideChanges: store.showsReviewPanel = false
        case .settings: store.isSettingsRequested = true
        case .checkForUpdates: store.updater.check(.manual)
        }
    }

    func title(in store: Store) -> String {
        guard !store.multiSelection.isEmpty, [.archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession].contains(self) else { return title }
        return title.replacing("Current Session", with: String(AttributedString(localized: "^[\(sessionIDs(in: store).count) Session](inflect: true)").characters))
    }

    private func sessionIDs(in store: Store) -> [String] {
        let ids = store.multiSelection.isEmpty ? [store.selection].compactMap { if case let .session(id) = $0 { id } else { nil } } : store.multiSelectedSessions.map(\.id)
        if self == .archiveCurrentSession { return ids.filter { id in store.activeSessions.contains { $0.id == id } } }
        if self == .flagCurrentSession { return ids.filter { !store.flaggedIDs.contains($0) } }
        if self == .unflagCurrentSession { return ids.filter(store.flaggedIDs.contains) }
        return []
    }

    func menuButton(_ store: Store) -> some View {
        Button(title) { perform(on: store) }
            .keyboardShortcut(shortcut)
    }
}
