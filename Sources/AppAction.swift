import BerthCore
import GhosttyTerminal
import SwiftUI

enum AppAction: Hashable {
    case commandPalette, filterSidebar, newSession, pullRequests, showPullRequestInReview, searchSessions, newTerminal, newTerminalForSession, switchTerminal, findInTerminal, clearTerminal, archiveCurrentSession, flagCurrentSession, unflagCurrentSession
    case groupBy(GroupingMode)
    case showTriage, hideTriage, newGroup, collapseAllGroups, expandAllGroups, showStats, harbor, showChanges, hideChanges, showChangesPane, showFilesPane, showTasksPane, showBrowser, openPreview, showSideBySide, showInline, wrapLines, showRenderedMarkdown, showMarkdownSource, showClaudeBelow, showClaudeBeside, showConversation, showTerminal, save, settings, checkForUpdates
    case goBack, goForward, previousChange, nextChange
    case openLocation, newBrowserTab, closeBrowserTab, reopenBrowserTab, reloadPage, browserBack, browserForward, showWebInspector
    case closeTerminal, copyTerminal, pasteTerminal, selectAllInTerminal, nextTab, previousTab
    case pinSession, unpinSession, snoozeHour, snoozeTomorrow, snoozeUntilNeeded, unsnoozeSession, unloadSession, reopenSession, copySessionID, markSessionRead, markSessionUnread, stopWatchingSession, newTaskFromSessions, removeSessionFromTask, reopenSessionTask, acceptTaskSuggestion, dismissTaskSuggestion
    case stopConversation, closeSubagentConversation
    case findInReview, refreshReview, toggleReviewTree, toggleReviewComments, collapseAllComments, expandAllComments, clearReviewMarks, sendReviewComments, closeReviewTab, closeOtherReviewTabs, closeReviewPreview, revealReviewFile, copyReviewPath, copyReviewRelativePath, openReviewFile
    case stopBrowserLoading, copyBrowserURL, openInDefaultBrowser
    case toggleIgnoredFiles, clearFilesFilter, openSelectedFile, revealSelectedFile, openFileInDefaultApp, copyFilePath, copyRelativeFilePath
    case caret(CaretAction)

    private static let launcherActions: [Self] = [.filterSidebar, .newSession, .pullRequests, .showPullRequestInReview, .searchSessions, .newTerminal, .newTerminalForSession, .switchTerminal, .findInTerminal, .clearTerminal, .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession]
    private static let workspaceActions: [Self] = [.showTriage, .hideTriage, .newGroup, .collapseAllGroups, .expandAllGroups, .showStats, .harbor, .showChanges, .hideChanges, .showChangesPane, .showFilesPane, .showTasksPane, .showBrowser, .openPreview, .showSideBySide, .showInline, .wrapLines, .showRenderedMarkdown, .showMarkdownSource, .showClaudeBelow, .showClaudeBeside, .showConversation, .showTerminal, .save, .settings, .checkForUpdates]
    private static let groupingActions = GroupingMode.allCases.map(Self.groupBy)
    private static let reviewNavigationActions: [Self] = [.goBack, .goForward, .previousChange, .nextChange]
    static let palette = launcherActions + workspaceActions + reviewNavigationActions + paletteOnlyActions + groupingActions + browser
    static let browser: [Self] = [.openLocation, .newBrowserTab, .closeBrowserTab, .reopenBrowserTab, .reloadPage, .browserBack, .browserForward, .showWebInspector]
    static let carets = CaretAction.allCases.map(Self.caret)
    static let routedPastTerminal = ([.commandPalette] + launcherActions + groupingActions + workspaceActions + carets + reviewNavigationActions).filter { $0.shortcut != nil }

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
        case .reopenBrowserTab: "Reopen Closed Tab"
        case .reloadPage: "Reload Page"
        case .browserBack: "Back"
        case .browserForward: "Forward"
        case .showWebInspector: "Show Web Inspector"
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
        case .closeTerminal: "Close Terminal"
        case .copyTerminal: "Copy Terminal Selection"
        case .pasteTerminal: "Paste into Terminal"
        case .selectAllInTerminal: "Select All in Terminal"
        case .nextTab: "Show Next Tab"
        case .previousTab: "Show Previous Tab"
        case .pinSession: "Pin Session"
        case .unpinSession: "Unpin Session"
        case .snoozeHour: "Snooze Session for 1 Hour"
        case .snoozeTomorrow: "Snooze Session Until Tomorrow"
        case .snoozeUntilNeeded: "Snooze Session Until It Needs You"
        case .unsnoozeSession: "Unsnooze Session"
        case .unloadSession: "Unload Session"
        case .reopenSession: "Mark Session as Not Done"
        case .copySessionID: "Copy Session ID"
        case .markSessionRead: "Mark Session as Read"
        case .markSessionUnread: "Mark Session as Unread"
        case .stopWatchingSession: "Stop Watching Pull Request"
        case .newTaskFromSessions: "New Task from Selected Sessions"
        case .removeSessionFromTask: "Remove Session from Task"
        case .reopenSessionTask: "Mark Session Task as Not Done"
        case .acceptTaskSuggestion: "Accept Task Suggestion"
        case .dismissTaskSuggestion: "Dismiss Task Suggestion"
        case .stopConversation: "Stop Conversation"
        case .closeSubagentConversation: "Close Subagent Conversation"
        case .findInReview: "Find in Review…"
        case .refreshReview: "Refresh Review"
        case .toggleReviewTree: "Toggle Changes Tree"
        case .toggleReviewComments: "Toggle Review Comments"
        case .collapseAllComments: "Collapse All Comments"
        case .expandAllComments: "Expand All Comments"
        case .clearReviewMarks: "Clear Review Marks"
        case .sendReviewComments: "Send Review Comments"
        case .closeReviewTab: "Close Review Tab"
        case .closeOtherReviewTabs: "Close Other Review Tabs"
        case .closeReviewPreview: "Close Review Preview"
        case .revealReviewFile: "Reveal in Files"
        case .copyReviewPath: "Copy Review File Path"
        case .copyReviewRelativePath: "Copy Relative Review File Path"
        case .openReviewFile: "Open Review File"
        case .stopBrowserLoading: "Stop Loading"
        case .copyBrowserURL: "Copy Page Link"
        case .openInDefaultBrowser: "Open in Default Browser"
        case .toggleIgnoredFiles: "Toggle Ignored Files"
        case .clearFilesFilter: "Clear Files Filter"
        case .openSelectedFile: "Open Selected File"
        case .revealSelectedFile: "Reveal Selected File in Finder"
        case .openFileInDefaultApp: "Open File in Default App"
        case .copyFilePath: "Copy File Path"
        case .copyRelativeFilePath: "Copy Relative File Path"
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
        case .closeTerminal: "shell tab unload"
        case .copyTerminal: "clipboard text"
        case .pasteTerminal: "clipboard text"
        case .selectAllInTerminal: "scrollback select text"
        case .nextTab: "cycle switch terminal session"
        case .previousTab: "cycle switch terminal session"
        case .pinSession: "sidebar favorite"
        case .unpinSession: "sidebar unfavorite"
        case .snoozeHour: "sidebar defer later"
        case .snoozeTomorrow: "sidebar defer later"
        case .snoozeUntilNeeded: "sidebar defer later attention"
        case .unsnoozeSession: "sidebar wake restore"
        case .unloadSession: "close tab shell"
        case .reopenSession: "unarchive reopen restore sidebar"
        case .copySessionID: "clipboard identifier uuid"
        case .markSessionRead: "sidebar unread activity"
        case .markSessionUnread: "sidebar unread activity"
        case .stopWatchingSession: "sidebar github pr watch"
        case .newTaskFromSessions: "sidebar multi selection group"
        case .removeSessionFromTask: "sidebar unlink"
        case .reopenSessionTask: "sidebar unarchive reopen task"
        case .acceptTaskSuggestion: "sidebar related sessions join"
        case .dismissTaskSuggestion: "sidebar not related decline"
        case .stopConversation: "interrupt cancel agent turn"
        case .closeSubagentConversation: "agent transcript back"
        case .findInReview: "search diff file text"
        case .refreshReview: "reload changes git diff"
        case .toggleReviewTree: "view as list tree file layout"
        case .toggleReviewComments: "show hide comment list"
        case .collapseAllComments, .expandAllComments: "diff inline threads fold unfold"
        case .clearReviewMarks: "diff agent marked notes dismiss remove"
        case .sendReviewComments: "paste pending comments into session"
        case .closeReviewTab: "diff file editor"
        case .closeOtherReviewTabs: "diff file editor"
        case .closeReviewPreview: "diff browser preview"
        case .revealReviewFile: "locate current review file"
        case .copyReviewPath: "clipboard absolute diff path"
        case .copyReviewRelativePath: "clipboard diff path"
        case .openReviewFile: "edit current diff file"
        case .stopBrowserLoading: "cancel page web navigation"
        case .copyBrowserURL: "copy url address clipboard"
        case .openInDefaultBrowser: "page url open external safari"
        case .toggleIgnoredFiles: "show hide files gitignore"
        case .clearFilesFilter: "reset files search"
        case .openSelectedFile: "files edit editor"
        case .revealSelectedFile: "files locate directory"
        case .openFileInDefaultApp: "files external"
        case .copyFilePath: "files clipboard absolute path"
        case .copyRelativeFilePath: "files clipboard path"
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
        case .openPreview, .showBrowser, .openLocation, .newBrowserTab, .closeBrowserTab, .reopenBrowserTab, .reloadPage, .showWebInspector: "globe"
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
        case .closeTerminal: "xmark"
        case .copyTerminal: "doc.on.doc"
        case .pasteTerminal: "clipboard"
        case .selectAllInTerminal: "selection.pin.in.out"
        case .nextTab: "chevron.right"
        case .previousTab: "chevron.left"
        case .pinSession: "pin"
        case .unpinSession: "pin.slash"
        case .snoozeHour: "clock"
        case .snoozeTomorrow: "clock"
        case .snoozeUntilNeeded: "clock"
        case .unsnoozeSession: "alarm"
        case .unloadSession: "xmark"
        case .reopenSession: "arrow.uturn.backward"
        case .copySessionID: "doc.on.doc"
        case .markSessionRead: "envelope.open"
        case .markSessionUnread: "envelope.badge"
        case .stopWatchingSession: "bell.slash"
        case .newTaskFromSessions: "plus.square.on.square"
        case .removeSessionFromTask: "minus.square"
        case .reopenSessionTask: "arrow.uturn.backward"
        case .acceptTaskSuggestion: "checkmark.circle"
        case .dismissTaskSuggestion: "xmark.circle"
        case .stopConversation: "stop.fill"
        case .closeSubagentConversation: "xmark"
        case .findInReview: "text.magnifyingglass"
        case .refreshReview: "arrow.clockwise"
        case .toggleReviewTree: "list.bullet.indent"
        case .toggleReviewComments: "bubble.left"
        case .collapseAllComments: "chevron.right"
        case .expandAllComments: "chevron.down"
        case .clearReviewMarks: "xmark.bubble"
        case .sendReviewComments: "paperplane"
        case .closeReviewTab: "xmark"
        case .closeOtherReviewTabs: "xmark"
        case .closeReviewPreview: "xmark"
        case .revealReviewFile: "folder"
        case .copyReviewPath: "doc.on.doc"
        case .copyReviewRelativePath: "doc.on.doc"
        case .openReviewFile: "doc"
        case .stopBrowserLoading: "xmark"
        case .copyBrowserURL: "link"
        case .openInDefaultBrowser: "arrow.up.forward.app"
        case .toggleIgnoredFiles: "eye"
        case .clearFilesFilter: "xmark.circle"
        case .openSelectedFile: "doc"
        case .revealSelectedFile: "folder"
        case .openFileInDefaultApp: "arrow.up.forward.app"
        case .copyFilePath: "doc.on.doc"
        case .copyRelativeFilePath: "doc.on.doc"
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
        case .reopenBrowserTab: KeyboardShortcut("t", modifiers: [.command, .shift])
        case .reloadPage: KeyboardShortcut("r")
        case .browserBack: KeyboardShortcut("[")
        case .browserForward: KeyboardShortcut("]")
        case .showWebInspector: KeyboardShortcut("i", modifiers: [.option, .command])
        case .wrapLines: KeyboardShortcut("z", modifiers: [.command, .option])
        case .showRenderedMarkdown, .showMarkdownSource: KeyboardShortcut("m", modifiers: [.command, .shift])
        case .showConversation, .showTerminal: KeyboardShortcut("j", modifiers: [.command, .option])
        case .save: KeyboardShortcut("s")
        case .settings: KeyboardShortcut(",")
        case .goBack: KeyboardShortcut("-", modifiers: .control)
        case .goForward: KeyboardShortcut("-", modifiers: [.control, .shift])
        case .previousChange: KeyboardShortcut(.upArrow, modifiers: [.control, .option])
        case .nextChange: KeyboardShortcut(.downArrow, modifiers: [.control, .option])
        case .closeTerminal: KeyboardShortcut("w")
        case .copyTerminal: KeyboardShortcut("c")
        case .pasteTerminal: KeyboardShortcut("v")
        case .selectAllInTerminal: KeyboardShortcut("a")
        case .nextTab: KeyboardShortcut("]", modifiers: [.command, .shift])
        case .previousTab: KeyboardShortcut("[", modifiers: [.command, .shift])
        case .findInReview: KeyboardShortcut("f")
        case .closeReviewTab: KeyboardShortcut("w")
        case let .caret(action): action.shortcut
        default: nil
        }
    }

    var shortcutLabel: String? {
        guard let shortcut else { return nil }

        let modifiers = [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let keys: [Character: String] = [KeyEquivalent.upArrow.character: "↑", KeyEquivalent.downArrow.character: "↓"]
        return modifiers.filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined() + (keys[shortcut.key.character] ?? String(shortcut.key.character).uppercased())
    }

    var contexts: Set<PaletteContext> {
        switch self {
        case .copyTerminal, .pasteTerminal, .selectAllInTerminal, .newTerminal, .switchTerminal: [.terminal]
        case .closeTerminal: [.terminal, .session]
        case .nextTab, .previousTab: [.terminal, .conversation]
        case .newTerminalForSession: [.terminal, .conversation, .session]
        case .pinSession, .unpinSession, .snoozeHour, .snoozeTomorrow, .snoozeUntilNeeded, .unsnoozeSession, .unloadSession, .reopenSession, .copySessionID, .markSessionRead, .markSessionUnread, .newTaskFromSessions, .removeSessionFromTask, .reopenSessionTask, .acceptTaskSuggestion, .dismissTaskSuggestion, .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession: [.session]
        case .stopWatchingSession: [.session, .conversation]
        case .stopConversation, .closeSubagentConversation, .showTerminal: [.conversation]
        case .newSession: [.conversation, .session]
        case .findInReview, .refreshReview, .toggleReviewTree, .toggleReviewComments, .collapseAllComments, .expandAllComments, .clearReviewMarks, .sendReviewComments, .closeReviewTab, .closeOtherReviewTabs, .closeReviewPreview, .revealReviewFile, .copyReviewPath, .copyReviewRelativePath, .openReviewFile, .goBack, .goForward, .previousChange, .nextChange, .save, .wrapLines, .showRenderedMarkdown, .showMarkdownSource, .showSideBySide, .showInline: [.review, .files]
        case .stopBrowserLoading, .copyBrowserURL, .openInDefaultBrowser, .openLocation, .newBrowserTab, .closeBrowserTab, .reopenBrowserTab, .reloadPage, .browserBack, .browserForward, .showWebInspector: [.browser]
        case .toggleIgnoredFiles, .clearFilesFilter, .openSelectedFile, .revealSelectedFile, .openFileInDefaultApp, .copyFilePath, .copyRelativeFilePath: [.files]
        case .findInTerminal, .clearTerminal, .showConversation: [.terminal]
        case .showChanges, .hideChanges, .showChangesPane, .showPullRequestInReview, .openPreview, .showClaudeBelow, .showClaudeBeside: [.review]
        case .showFilesPane: [.files]
        case .showBrowser: [.browser]
        default: []
        }
    }

    func isAvailable(in store: Store) -> Bool {
        switch self {
        case .showPullRequestInReview: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.selectedSessionID != nil

        case .newTerminalForSession: store.launcherMode == .palette && store.paletteContext == .session ? !sessionTabs(in: store).isEmpty && store.multiSelection.isEmpty : store.sessionTab != nil

        case .findInTerminal: store.focusedTerminal != nil && !store.isHarborShown && (store.selectedTabID != store.mainTabID || !store.selectedShowsConversation)

        case .clearTerminal: store.focusedTerminal != nil && (store.launcherMode != .palette || terminalView(in: store) != nil)

        case .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession:
            !sessionIDs(in: store).isEmpty

        case let .groupBy(mode): store.groupingMode != mode

        case .showTriage: !store.showsTriage

        case .hideTriage: store.showsTriage

        case .showChanges: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && (!store.showsReviewPanel || store.isHarborShown)

        case .hideChanges: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.showsReviewPanel && !store.isHarborShown

        case .showChangesPane, .showFilesPane: UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && store.sessionTab != nil

        case .showTasksPane: store.canShowTasksPane

        case .showBrowser: store.sessionTab != nil

        case _ where store.launcherMode == .palette && Self.browser.contains(self): isBrowserActionAvailableInPalette(in: store)

        case .openLocation: store.shownPane == .browser

        case .newBrowserTab, .closeBrowserTab, .reopenBrowserTab, .reloadPage, .browserBack, .browserForward:
            store.shownPane == .browser && (NSApp.keyWindow?.firstResponder as? NSView).map { sequence(first: $0, next: \.superview).contains { $0 is NSHostingView<PaneHost> } } == true

        case .showWebInspector: Self.reloadPage.isAvailable(in: store) && store.browser.shownTab?.canShowInspector == true

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

        case .goBack, .goForward: canNavigateReview(in: store) && store.reviewModel?.selectedTab.map { $0.history.indices.contains($0.index + (self == .goBack ? -1 : 1)) } == true

        case .previousChange, .nextChange: canNavigateReview(in: store) && store.reviewModel?.selectedDocument?.compare != nil

        case .caret: store.isReviewTextFocused

        case .commandPalette, .filterSidebar, .newSession, .pullRequests, .searchSessions, .newTerminal, .switchTerminal,
             .newGroup, .collapseAllGroups, .expandAllGroups, .showStats, .harbor, .settings, .checkForUpdates: true

        default: store.launcherMode == .palette && isAvailableInContext(in: store)
        }
    }

    func perform(on store: Store) {
        switch self {
        case .commandPalette: togglePalette(in: store)

        case .filterSidebar:
            store.launcherMode = nil
            store.isHarborShown = false
            store.sidebarFilterFocusRequests += 1

        case .newSession: store.launcherMode = .newSession

        case .pullRequests: store.launcherMode = .pullRequests

        case .showPullRequestInReview: if isAvailable(in: store) { store.launcherMode = .showPullRequestInReview }

        case .searchSessions: store.launcherMode = .search

        case .newTerminal: store.newTerminal()

        case .newTerminalForSession: openTerminalForSession(in: store)

        case .switchTerminal: store.switchTerminal()

        case .findInTerminal: if isAvailable(in: store) { store.selectFocusedSurface(); store.focusedTerminal?.performBindingAction("start_search") }

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

        case .showBrowser: toggleBrowser(in: store)

        case .openLocation: openBrowserLocation(in: store)

        case .newBrowserTab, .closeBrowserTab, .reopenBrowserTab, .reloadPage, .browserBack, .browserForward, .showWebInspector: store.browser.perform(self)

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

        default: performInContext(on: store)
        }
    }

    private func togglePalette(in store: Store) {
        if store.launcherMode == .palette {
            store.launcherMode = nil
        } else {
            store.paletteContext = PaletteContext(in: store)
            store.paletteResponder = NSApp.keyWindow?.firstResponder
            store.launcherQuery = ""
            store.launcherMode = .palette
        }
    }

    private func openTerminalForSession(in store: Store) {
        let tab = if store.launcherMode == .palette, store.paletteContext == .session {
            store.multiSelection.isEmpty ? sessionTabs(in: store).first : nil
        } else {
            store.sessionTab
        }
        if let tab { store.newTerminal(for: tab.id) }
    }

    private func toggleBrowser(in store: Store) {
        if store.shownPane == .browser { store.hideSessionPanel() } else { store.showBrowserPane() }
    }

    private func openBrowserLocation(in store: Store) {
        if store.launcherMode == .palette {
            store.launcherMode = nil
            DispatchQueue.main.async {
                if store.launcherMode == nil, isAvailable(in: store) { store.browser.perform(self) }
            }
        } else {
            store.browser.perform(self)
        }
    }

    func title(in store: Store) -> String {
        if store.launcherMode != .palette {
            guard !store.multiSelection.isEmpty, [.archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession].contains(self) else { return title }

            return title.replacing("Current Session", with: String(AttributedString(localized: "^[\(sessionIDs(in: store).count) Session](inflect: true)").characters))
        }

        if self == .toggleReviewTree { return UserDefaults.standard.bool(forKey: ReviewModel.changesAsTreeKey) ? "View Changes as List" : "View Changes as Tree" }
        if self == .toggleReviewComments { return store.primaryReviewModel?.showsCommentList == true ? "Hide Review Comments" : "Show Review Comments" }
        if self == .toggleIgnoredFiles { return currentFiles(in: store)?.showsIgnored == true ? "Hide Ignored Files" : "Show Ignored Files" }
        if self == .showBrowser, store.shownPane == .browser { return "Hide Browser" }
        guard !store.multiSelection.isEmpty else { return title }

        let label: String.LocalizationValue
        switch self {
        case .closeTerminal: label = "Close ^[\(terminalTabs(in: store).count) Terminal](inflect: true)"
        case .unloadSession: label = "Unload ^[\(sessionTabs(in: store).count) Session](inflect: true)"
        case .pinSession: label = "Pin ^[\(sessionIDs(in: store).count) Session](inflect: true)"
        case .unpinSession: label = "Unpin ^[\(sessionIDs(in: store).count) Session](inflect: true)"
        case .markSessionRead: label = "Mark ^[\(sessionIDs(in: store).count) Session](inflect: true) as Read"
        case .markSessionUnread: label = "Mark ^[\(sessionIDs(in: store).count) Session](inflect: true) as Unread"
        case .archiveCurrentSession: label = "Mark ^[\(sessionIDs(in: store).count) Session](inflect: true) as Done"
        case .flagCurrentSession: label = "Flag ^[\(sessionIDs(in: store).count) Session](inflect: true)"
        case .unflagCurrentSession: label = "Unflag ^[\(sessionIDs(in: store).count) Session](inflect: true)"
        default: return title
        }
        return String(AttributedString(localized: label).characters)
    }

    func sessionIDs(in store: Store) -> [String] {
        let item = sidebarItem(in: store)
        let ids: [String] = if !store.multiSelection.isEmpty {
            store.multiSelectedSessions.map(\.id)
        } else if case let .session(id)? = item {
            [id]
        } else if store.launcherMode == .palette, case let .tab(id)? = item, let sessionID = store.tabs.first(where: { $0.id == id })?.sessionID {
            [sessionID]
        } else {
            []
        }
        switch self {
        case .archiveCurrentSession: return ids.filter { id in store.activeSessions.contains { $0.id == id } }
        case .flagCurrentSession: return ids.filter { !store.flaggedIDs.contains($0) }
        case .unflagCurrentSession: return ids.filter(store.flaggedIDs.contains)
        case .copySessionID: return store.multiSelection.isEmpty ? ids : []
        case .stopWatchingSession:
            return store.multiSelection.isEmpty ? ids.filter { store.pullRequestWatch(for: $0) != nil && store.tab(forSession: $0) != nil && store.liveBySession[$0]?.status != "waiting" } : []
        case .reopenSession, .reopenSessionTask:
            return store.multiSelection.isEmpty ? store.archivedSessions.map(\.id).filter { ids.contains($0) && (self == .reopenSession || store.task(containing: $0) != nil) } : []
        default: break
        }
        let active = ids.compactMap { id in store.activeSessions.first { $0.id == id } }
        return active.filter { session in
            let id = session.id
            switch self {
            case .pinSession: return !store.pinnedSessions.contains { $0.id == id } && (store.multiSelection.isEmpty || store.snooze(of: id) == nil)
            case .unpinSession: return store.pinnedSessions.contains { $0.id == id }
            case .snoozeHour, .snoozeTomorrow, .snoozeUntilNeeded: return store.multiSelection.isEmpty
            case .unsnoozeSession: return store.multiSelection.isEmpty && store.snooze(of: id) != nil
            case .markSessionRead: return store.isUnread(session)
            case .markSessionUnread: return !store.isUnread(session) && store.selection != .session(id)
            case .removeSessionFromTask: return store.multiSelection.isEmpty && store.task(containing: id) != nil
            case .acceptTaskSuggestion, .dismissTaskSuggestion: return store.multiSelection.isEmpty && store.taskSuggestions[id] != nil
            default: return true
            }
        }.map(\.id)
    }

    private func sidebarItem(in store: Store) -> SidebarItem? {
        if store.launcherMode == .palette, store.paletteContext == .session { return store.sidebarCursor ?? store.selection }
        return store.selection
    }

    func sessionTabs(in store: Store) -> [Tab] {
        if !store.multiSelection.isEmpty { return store.multiSelectedTabs.filter { $0.kind == .claude } }
        switch sidebarItem(in: store) {
        case let .session(id): return store.tab(forSession: id).map { [$0] } ?? []
        case let .tab(id): return store.tabs.filter { $0.id == id && $0.kind == .claude }
        default: return []
        }
    }

    func terminalTabs(in store: Store) -> [Tab] {
        if !store.multiSelection.isEmpty { return store.multiSelectedTabs.filter { $0.kind == .shell } }
        guard !store.isHarborShown, store.selectedTabID != store.mainTabID || !store.selectedShowsConversation, let terminal = store.focusedTerminal else { return [] }

        return store.tabs.filter { $0.kind == .shell && $0.terminal === terminal }
    }

    func terminalView(in store: Store) -> TerminalView? {
        guard !store.isHarborShown, store.selectedTabID != store.mainTabID || !store.selectedShowsConversation else { return nil }

        return store.focusedTerminal?.attachedPlatformView
    }

    private func canNavigateReview(in store: Store) -> Bool {
        store.isReviewTextFocused || store.launcherMode == .palette && (store.shownPane == .changes || store.shownPane == .files)
    }

    func currentFiles(in store: Store) -> FilesModel? {
        guard store.shownPane == .files, let session = store.sessionTab else { return nil }

        return store.filesModels[session.id]
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
