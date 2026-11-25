import BerthCore
import GhosttyTerminal
import SwiftUI

enum AppAction: Hashable {
    case commandPalette, filterSidebar, newSession, pullRequests, showPullRequestInReview, searchSessions, newTerminal, newTerminalForSession, switchTerminal, findInTerminal, clearTerminal, archiveCurrentSession, flagCurrentSession, unflagCurrentSession
    case groupBy(GroupingMode)
    case showTriage, hideTriage, newGroup, collapseAllGroups, expandAllGroups, showStats, harbor, showChanges, hideChanges, showChangesPane, showFilesPane, showTasksPane, showBrowser, openPreview, showSideBySide, showInline, wrapLines, showRenderedMarkdown, showMarkdownSource, showClaudeBelow, showClaudeBeside, showConversation, showTerminal, save, settings, checkForUpdates
    case goBack, goForward, previousChange, nextChange
    case openLocation, newBrowserTab, closeBrowserTab, reloadPage, browserBack, browserForward
    case caret(CaretAction)

    static let palette: [Self] = [.filterSidebar, .newSession, .pullRequests, .showPullRequestInReview, .searchSessions, .newTerminal, .newTerminalForSession, .switchTerminal, .findInTerminal, .clearTerminal, .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession]
        + GroupingMode.allCases.map(Self.groupBy)
        + [.showTriage, .hideTriage, .newGroup, .collapseAllGroups, .expandAllGroups, .showStats, .harbor, .showChanges, .hideChanges, .showChangesPane, .showFilesPane, .showTasksPane, .showBrowser, .openPreview, .showSideBySide, .showInline, .wrapLines, .showRenderedMarkdown, .showMarkdownSource, .showClaudeBelow, .showClaudeBeside, .showConversation, .showTerminal, .save, .settings, .checkForUpdates]
    static let browser: [Self] = [.openLocation, .newBrowserTab, .closeBrowserTab, .reloadPage, .browserBack, .browserForward]
    static let carets = CaretAction.allCases.map(Self.caret)
    static let routedPastTerminal = ([.commandPalette] + palette + carets + [.goBack, .goForward, .previousChange, .nextChange]).filter { $0.shortcut != nil }

    var title: String {
        switch self {
        case .commandPalette: "Command Palette…"
        case .filterSidebar: "Filter Sidebar"
        case .newSession: "New Session…"
        case .pullRequests: "Open Pull Request…"
        case .showPullRequestInReview: "Show Pull Request in Review…"
        case .searchSessions: "Search Sessions…"
        case .newTerminal: "New Terminal"
        case .newTerminalForSession: "New Terminal for Session"
        case .switchTerminal: "Toggle Terminal"
        case .findInTerminal: "Find…"
        case .clearTerminal: "Clear Terminal"
        case .archiveCurrentSession: "Mark Current Session as Done"
        case .flagCurrentSession: "Flag Current Session"
        case .unflagCurrentSession: "Unflag Current Session"
        case let .groupBy(mode): "Group By \(mode.title)"
        case .showTriage: "Show Triage"
        case .hideTriage: "Hide Triage"
        case .newGroup: "New Group…"
        case .collapseAllGroups: "Collapse All Groups"
        case .expandAllGroups: "Expand All Groups"
        case .showStats: "Show Stats"
        case .harbor: "Harbor"
        case .showChanges: "Show Changes"
        case .hideChanges: "Hide Changes"
        case .showChangesPane: "Show Changes Pane"
        case .showFilesPane: "Show Files Pane"
        case .showTasksPane: "Show Tasks Pane"
        case .showBrowser: "Show Browser"
        case .openLocation: "Open Location…"
        case .newBrowserTab: "New Browser Tab"
        case .closeBrowserTab: "Close Browser Tab"
        case .reloadPage: "Reload Page"
        case .browserBack: "Back"
        case .browserForward: "Forward"
        case .openPreview: "Open Preview"
        case .showSideBySide: "Show Side by Side"
        case .showInline: "Show Inline"
        case .wrapLines: "Wrap Lines"
        case .showRenderedMarkdown: "Show Rendered Markdown"
        case .showMarkdownSource: "Show Markdown Source"
        case .showClaudeBelow: "Show Claude Below Diff"
        case .showClaudeBeside: "Show Claude Beside Diff"
        case .showConversation: "Show Conversation"
        case .showTerminal: "Show Terminal"
        case .save: "Save"
        case .settings: "Settings…"
        case .checkForUpdates: "Check for Updates…"
        case .goBack: "Go Back"
        case .goForward: "Go Forward"
        case .previousChange: "Previous Change"
        case .nextChange: "Next Change"
        case let .caret(action): action.rawValue
        }
    }

    var keywords: String {
        switch self {
        case .newSession: "claude start folder"
        case .pullRequests: "github pr review requested mine assigned checkout worktree"
        case .showPullRequestInReview: "github pr diff changes current tab"
        case .filterSidebar: "search sessions tasks terminals narrow"
        case .searchSessions: "find transcripts"
        case .newTerminal, .newTerminalForSession: "shell tab"
        case .switchTerminal: "shell toggle jump pane session"
        case .findInTerminal: "search terminal scrollback text"
        case .clearTerminal: "screen scrollback"
        case .flagCurrentSession, .unflagCurrentSession: "follow up mark"
        case .archiveCurrentSession: "archive done finish"
        case .showTriage, .hideTriage: "sidebar inbox needs you working unread sections"
        case .groupBy: "sidebar"
        case .showStats: "usage tokens charts activity"
        case .harbor: "ambient boats piers overview"
        case .showChanges, .hideChanges: "review diff branch changes comments panel"
        case .showChangesPane: "review diff pane column"
        case .showFilesPane: "files folder tree explorer pane column"
        case .showTasksPane: "background tasks agents shells output pane column"
        case .showBrowser: "web page url tabs pane localhost"
        case .openPreview: "browser web localhost dev server pick element review"
        case .showSideBySide, .showInline: "review diff layout split unified inline toggle"
        case .wrapLines: "review diff soft wrap long lines word wrap horizontal scroll"
        case .showRenderedMarkdown, .showMarkdownSource: "review file viewer markdown md render rendered preview source raw toggle"
        case .showClaudeBelow, .showClaudeBeside: "review terminal claude diff layout below beside under vertical horizontal"
        case .showConversation, .showTerminal: "conversation chat gui transcript terminal claude view"
        case .save: "review file edits write disk"
        case .settings: "preferences"
        case .checkForUpdates: "update version release"
        default: ""
        }
    }

    var symbol: String {
        switch self {
        case .commandPalette: "command"
        case .filterSidebar: "line.3.horizontal.decrease"
        case .newSession: "plus.bubble"
        case .pullRequests, .showPullRequestInReview: "arrow.triangle.pull"
        case .searchSessions: "magnifyingglass"
        case .newTerminal, .newTerminalForSession: "plus.rectangle"
        case .switchTerminal: "apple.terminal"
        case .findInTerminal: "text.magnifyingglass"
        case .clearTerminal: "eraser"
        case .archiveCurrentSession: "archivebox"
        case .flagCurrentSession: "flag"
        case .unflagCurrentSession: "flag.slash"
        case .groupBy: "square.grid.3x1.below.line.grid.1x2"
        case .showTriage, .hideTriage: "tray"
        case .newGroup: "folder.badge.plus"
        case .collapseAllGroups: "rectangle.compress.vertical"
        case .expandAllGroups: "rectangle.expand.vertical"
        case .showStats: "chart.bar.xaxis"
        case .harbor: "sailboat"
        case .showChanges, .hideChanges, .showChangesPane: "plus.forwardslash.minus"
        case .showFilesPane: "folder"
        case .showTasksPane: "list.bullet.rectangle"
        case .openPreview, .showBrowser, .openLocation, .newBrowserTab, .closeBrowserTab, .reloadPage: "globe"
        case .browserBack: "chevron.backward"
        case .browserForward: "chevron.forward"
        case .showSideBySide: "rectangle.split.2x1"
        case .showInline: "rectangle"
        case .wrapLines: "arrow.turn.down.left"
        case .showRenderedMarkdown: "doc.richtext"
        case .showMarkdownSource: "doc.plaintext"
        case .showClaudeBelow: "rectangle.bottomhalf.inset.filled"
        case .showClaudeBeside: "rectangle.righthalf.inset.filled"
        case .showConversation: "text.bubble"
        case .showTerminal: "apple.terminal"
        case .save: "square.and.arrow.down"
        case .settings: "gear"
        case .checkForUpdates: "arrow.down.circle"
        case .goBack: "chevron.backward"
        case .goForward: "chevron.forward"
        case .previousChange: "chevron.up"
        case .nextChange: "chevron.down"
        case .caret: "character.cursor.ibeam"
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .commandPalette: KeyboardShortcut("k")
        case .filterSidebar: KeyboardShortcut("f", modifiers: [.command, .option])
        case .newSession: KeyboardShortcut("n")
        case .showPullRequestInReview: KeyboardShortcut("r", modifiers: [.command, .option])
        case .searchSessions: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .newTerminal: KeyboardShortcut("t")
        case .switchTerminal: KeyboardShortcut("j")
        case .findInTerminal: KeyboardShortcut("f")
        case .clearTerminal: KeyboardShortcut("k", modifiers: [.command, .option])
        case let .groupBy(mode): KeyboardShortcut(KeyEquivalent(Character("\((GroupingMode.allCases.firstIndex(of: mode) ?? 0) + 1)")), modifiers: [.control, .command])
        case .showStats: KeyboardShortcut("s", modifiers: [.command, .shift])
        case .showChanges, .hideChanges: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .showChangesPane: KeyboardShortcut("d", modifiers: [.command, .shift])
        case .showFilesPane: KeyboardShortcut("e", modifiers: [.command, .shift])
        case .showTasksPane: KeyboardShortcut("a", modifiers: [.command, .shift])
        case .showBrowser: KeyboardShortcut("b", modifiers: [.command, .shift])
        case .openLocation: KeyboardShortcut("l")
        case .newBrowserTab: KeyboardShortcut("t")
        case .closeBrowserTab: KeyboardShortcut("w")
        case .reloadPage: KeyboardShortcut("r")
        case .browserBack: KeyboardShortcut("[")
        case .browserForward: KeyboardShortcut("]")
        case .wrapLines: KeyboardShortcut("z", modifiers: [.command, .option])
        case .showRenderedMarkdown, .showMarkdownSource: KeyboardShortcut("m", modifiers: [.command, .shift])
        case .showConversation, .showTerminal: KeyboardShortcut("j", modifiers: [.command, .option])
        case .save: KeyboardShortcut("s")
        case .settings: KeyboardShortcut(",")
        case .goBack: KeyboardShortcut("-", modifiers: .control)
        case .goForward: KeyboardShortcut("-", modifiers: [.control, .shift])
        case .previousChange: KeyboardShortcut(.upArrow, modifiers: [.control, .option])
        case .nextChange: KeyboardShortcut(.downArrow, modifiers: [.control, .option])
        case let .caret(action): action.shortcut
        default: nil
        }
    }

    func isAvailable(in store: Store) -> Bool {
        switch self {
        case .showPullRequestInReview: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.selectedSessionID != nil
        case .newTerminalForSession: store.sessionTab != nil
        case .findInTerminal: store.focusedTerminal != nil && !store.isHarborShown && !store.selectedShowsConversation
        case .clearTerminal: store.focusedTerminal != nil
        case .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession: !sessionIDs(in: store).isEmpty
        case let .groupBy(mode): store.groupingMode != mode
        case .showTriage: !store.showsTriage
        case .hideTriage: store.showsTriage
        case .showChanges: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && (!store.showsReviewPanel || store.isHarborShown)
        case .hideChanges: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.showsReviewPanel && !store.isHarborShown
        case .showChangesPane, .showFilesPane: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.sessionTab != nil
        case .showTasksPane: store.canShowTasksPane
        case .showBrowser: store.sessionTab != nil
        case .openLocation: store.shownPane == .browser
        case .newBrowserTab, .closeBrowserTab, .reloadPage, .browserBack, .browserForward:
            store.shownPane == .browser && (NSApp.keyWindow?.firstResponder as? NSView).map { sequence(first: $0, next: \.superview).contains { $0 is NSHostingView<PaneHost> } } == true
        case .openPreview: Self.hideChanges.isAvailable(in: store) && store.reviewModel?.isPreviewSelected == false
        case .showSideBySide, .showInline:
            Self.hideChanges.isAvailable(in: store) && store.reviewModel?.selectedDocumentHasBothSides == true && store.isReviewDiffUnified == (self == .showSideBySide)
        case .wrapLines: Self.hideChanges.isAvailable(in: store)
        case .showRenderedMarkdown, .showMarkdownSource:
            Self.hideChanges.isAvailable(in: store) && store.reviewModel?.selectedDocument?.isMarkdown == true && store.rendersMarkdown == (self == .showMarkdownSource)
        case .showClaudeBelow, .showClaudeBeside:
            Self.hideChanges.isAvailable(in: store) && UserDefaults.standard.bool(forKey: GeneralSettings.terminalBelowKey) == (self == .showClaudeBeside)
        case .showConversation: store.canShowConversation && !store.selectedShowsConversation
        case .showTerminal: store.canShowConversation && store.selectedShowsConversation
        case .save: Self.hideChanges.isAvailable(in: store) && store.reviewModel.flatMap { model in model.selectedDocument.flatMap { $0.compare?.isHistorical == true ? nil : model.drafts[$0.path] } } != nil
        case .goBack, .goForward: store.isReviewTextFocused && store.reviewModel?.selectedTab.map { $0.history.indices.contains($0.index + (self == .goBack ? -1 : 1)) } == true
        case .previousChange, .nextChange: store.isReviewTextFocused && store.reviewModel?.selectedDocument?.compare != nil
        case .caret: store.isReviewTextFocused
        default: true
        }
    }

    func perform(on store: Store) {
        switch self {
        case .commandPalette: store.launcherMode = store.launcherMode == .palette ? nil : .palette

        case .filterSidebar:
            store.launcherMode = nil
            store.isHarborShown = false
            store.sidebarFilterFocusRequests += 1

        case .newSession: store.launcherMode = .newSession

        case .pullRequests: store.launcherMode = .pullRequests

        case .showPullRequestInReview: if isAvailable(in: store) { store.launcherMode = .showPullRequestInReview }

        case .searchSessions: store.launcherMode = .search

        case .newTerminal: store.newTerminal()

        case .newTerminalForSession:
            if let id = store.sessionTab?.id { store.newTerminal(for: id) }

        case .switchTerminal: store.switchTerminal()

        case .findInTerminal: if isAvailable(in: store) { store.focusedTerminal?.performBindingAction("start_search") }

        case .clearTerminal: store.focusedTerminal?.performBindingAction("clear_screen")

        case .archiveCurrentSession: for id in sessionIDs(in: store) { store.archive(id) }

        case .flagCurrentSession: for id in sessionIDs(in: store) { store.flag(id) }

        case .unflagCurrentSession: for id in sessionIDs(in: store) { store.unflag(id) }

        case let .groupBy(mode): store.groupingMode = mode

        case .showTriage, .hideTriage: store.showsTriage = self == .showTriage

        case .newGroup: store.editingGroup = CustomGroup(name: "", rules: [])

        case .collapseAllGroups: store.setGroupsExpanded(false)

        case .expandAllGroups: store.setGroupsExpanded(true)

        case .showStats: store.isStatsRequested = true

        case .harbor: store.isHarborShown.toggle()

        case .showChanges, .showChangesPane, .showFilesPane: store.showReviewPane(self == .showFilesPane ? .files : .changes)

        case .showBrowser: if store.shownPane == .browser { store.hideSessionPanel() } else { store.showBrowserPane() }

        case .openLocation, .newBrowserTab, .closeBrowserTab, .reloadPage, .browserBack, .browserForward: store.browser.perform(self)

        case .hideChanges: store.hideSessionPanel()

        case .showTasksPane: store.showTasksPane()

        case .openPreview: store.reviewModel?.showPreview()

        case .showSideBySide: UserDefaults.standard.set(ReviewDiffLayout.sideBySide.rawValue, forKey: ReviewDiffLayout.key)

        case .showInline: UserDefaults.standard.set(ReviewDiffLayout.inline.rawValue, forKey: ReviewDiffLayout.key)

        case .wrapLines: UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: ReviewStyle.wrapsLinesKey), forKey: ReviewStyle.wrapsLinesKey)

        case .showRenderedMarkdown, .showMarkdownSource: store.rendersMarkdown = self == .showRenderedMarkdown

        case .showClaudeBelow, .showClaudeBeside: UserDefaults.standard.set(self == .showClaudeBelow, forKey: GeneralSettings.terminalBelowKey)

        case .showConversation, .showTerminal: if isAvailable(in: store) { store.setConversation(self == .showConversation) }

        case .save:
            if isAvailable(in: store), let model = store.reviewModel, let path = model.selectedDocument?.path, let text = model.editors[path]?.string { model.save(text, to: path) }

        case .settings: store.isSettingsRequested = true

        case .checkForUpdates: store.updater.check(.manual)

        case .goBack, .goForward: if isAvailable(in: store) { store.reviewModel?.go(by: self == .goBack ? -1 : 1) }

        case .previousChange, .nextChange: if isAvailable(in: store) { store.reviewModel?.changeStep = self == .nextChange ? 1 : -1 }

        case let .caret(action): (NSApp.keyWindow?.firstResponder as? ReviewTextView)?.performCaretAction(action)
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

enum CaretAction: String, CaseIterable {
    case addCursorAbove = "Add Cursor Above"
    case addCursorBelow = "Add Cursor Below"
    case addNextOccurrence = "Add Next Occurrence"
    case moveLastSelectionToNextOccurrence = "Move Last Selection to Next Occurrence"
    case selectAllOccurrences = "Select All Occurrences"
    case changeAllOccurrences = "Change All Occurrences"
    case addCursorsToLineEnds = "Add Cursors to Line Ends"
    case undoCursor = "Undo Last Cursor Operation"
    case collapseCursors = "Collapse to One Cursor"

    var shortcut: KeyboardShortcut? {
        switch self {
        case .addCursorAbove: KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .addCursorBelow: KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .addNextOccurrence: KeyboardShortcut("d")
        case .selectAllOccurrences: KeyboardShortcut("l", modifiers: [.command, .shift])
        case .changeAllOccurrences: KeyboardShortcut(KeyEquivalent(Character("\u{F705}")))
        case .addCursorsToLineEnds: KeyboardShortcut("i", modifiers: [.shift, .option])
        case .undoCursor: KeyboardShortcut("u")
        case .moveLastSelectionToNextOccurrence, .collapseCursors: nil
        }
    }
}
