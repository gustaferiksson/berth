import BerthCore
import GhosttyTerminal
import SwiftUI
import WebKit

extension AppAction {
    static let paletteOnlyActions: [Self] = [
        .closeTerminal, .copyTerminal, .pasteTerminal, .selectAllInTerminal, .nextTab, .previousTab,
        .pinSession, .unpinSession, .snoozeHour, .snoozeTomorrow, .snoozeUntilNeeded, .unsnoozeSession, .unloadSession, .reopenSession, .copySessionID, .markSessionRead, .markSessionUnread, .stopWatchingSession, .newTaskFromSessions, .removeSessionFromTask, .reopenSessionTask, .acceptTaskSuggestion, .dismissTaskSuggestion,
        .stopConversation, .closeSubagentConversation,
        .findInReview, .refreshReview, .toggleReviewTree, .toggleReviewComments, .collapseAllComments, .expandAllComments, .clearReviewMarks, .sendReviewComments, .closeReviewTab, .closeOtherReviewTabs, .closeReviewPreview, .revealReviewFile, .copyReviewPath, .copyReviewRelativePath, .openReviewFile,
        .stopBrowserLoading, .copyBrowserURL, .openInDefaultBrowser,
        .toggleIgnoredFiles, .clearFilesFilter, .openSelectedFile, .revealSelectedFile, .openFileInDefaultApp, .copyFilePath, .copyRelativeFilePath,
    ]

    func isBrowserActionAvailableInPalette(in store: Store) -> Bool {
        guard store.shownPane == .browser else { return false }

        return switch self {
        case .openLocation, .newBrowserTab: store.browser.sessionKey != nil
        case .closeBrowserTab: store.browser.shownTab != nil
        case .reopenBrowserTab: store.browser.canReopenClosedTab
        case .reloadPage: store.browser.shownTab?.loadedWebView != nil && store.browser.shownTab?.url != nil
        case .browserBack: store.browser.shownTab?.canGoBack == true
        case .browserForward: store.browser.shownTab?.canGoForward == true
        case .showWebInspector: store.browser.shownTab?.canShowInspector == true
        default: false
        }
    }

    func isAvailableInContext(in store: Store) -> Bool {
        switch self {
        case .pinSession, .unpinSession, .reopenSession, .snoozeHour, .snoozeTomorrow, .snoozeUntilNeeded, .unsnoozeSession,
             .markSessionRead, .markSessionUnread, .removeSessionFromTask, .reopenSessionTask, .stopWatchingSession,
             .acceptTaskSuggestion, .dismissTaskSuggestion:
            !sessionIDs(in: store).isEmpty

        case .newTaskFromSessions: sessionIDs(in: store).count > 1

        case .copySessionID: sessionIDs(in: store).count == 1

        case .closeTerminal: !terminalTabs(in: store).isEmpty

        case .unloadSession: !sessionTabs(in: store).isEmpty

        case .copyTerminal: terminalView(in: store)?.selectionMenuPoint(at: .zero) != nil

        case .pasteTerminal: terminalView(in: store) != nil && NSPasteboard.general.string(forType: .string) != nil

        case .selectAllInTerminal: terminalView(in: store) != nil

        case .nextTab, .previousTab: store.sidebarOrderedTabs.count > 1

        case .stopConversation:
            store.selectedStatusBarIsReachable && store.mainTabID.flatMap { store.conversationModels[$0] }.map { model in
                model.draft.isEmpty && model.isWorking(with: store.selectedSessionID.flatMap { store.liveBySession[$0] })
            } == true

        case .closeSubagentConversation: store.selectedConversationIsVisible && store.mainTabID.flatMap { store.conversationModels[$0]?.openSubagent } != nil

        case .stopBrowserLoading: store.shownPane == .browser && store.browser.shownTab?.isLoading == true && store.browser.shownTab?.loadedWebView != nil

        case .copyBrowserURL, .openInDefaultBrowser: store.shownPane == .browser && store.browser.shownTab?.url != nil

        case .findInReview: (store.paletteResponder as? ReviewTextView)?.window != nil

        case .refreshReview: store.shownPane == .changes && store.primaryReviewModel?.isLoading == false

        case .toggleReviewTree: store.shownPane == .changes && hasReviewTreeChanges(in: store)

        case .collapseAllComments, .expandAllComments: store.shownPane == .changes && store.reviewModel?.selectedDocument?.compare != nil

        case .clearReviewMarks: store.shownPane == .changes && store.selectedSessionID.flatMap { store.reviewMarks[$0] }?.isEmpty == false

        case .toggleReviewComments, .sendReviewComments:
            store.showsReviewPanel && (store.shownPane == .changes || store.shownPane == .browser) && store.sessionReviewModels.contains { !$0.isSessionFiles && !$0.comments.isEmpty }
                && (self == .toggleReviewComments || store.selectedSessionID.map { store.liveBySession[$0] != nil || store.selectedShowsConversation } == true)

        case .closeReviewTab: (store.shownPane == .changes || store.shownPane == .files) && store.reviewModel?.selectedTab != nil && store.reviewModel?.isPreviewSelected == false

        case .closeOtherReviewTabs: Self.closeReviewTab.isAvailable(in: store) && (store.reviewModel?.tabs.count ?? 0) > 1

        case .closeReviewPreview: (store.shownPane == .changes || store.shownPane == .files) && store.reviewModel?.isPreviewOpen == true

        case .copyReviewPath: Self.closeReviewTab.isAvailable(in: store) && reviewFilePath(in: store) != nil

        case .copyReviewRelativePath: Self.closeReviewTab.isAvailable(in: store) && store.reviewModel?.selectedDocument?.path.isEmpty == false

        case .revealReviewFile: Self.copyReviewPath.isAvailable(in: store) && store.reviewModel === store.primaryReviewModel && store.reviewModel?.selectedDocument?.pullRequestLink == nil
            && reviewFilePath(in: store).map { FileManager.default.fileExists(atPath: $0) } == true

        case .openReviewFile: Self.copyReviewPath.isAvailable(in: store) && store.reviewModel?.selectedDocument?.compare != nil
            && store.reviewModel?.selectedDocument?.pullRequestLink == nil && reviewFilePath(in: store).map { FileManager.default.fileExists(atPath: $0) } == true

        case .toggleIgnoredFiles: currentFiles(in: store) != nil

        case .clearFilesFilter: currentFiles(in: store)?.filter.isEmpty == false

        case .openSelectedFile, .revealSelectedFile, .openFileInDefaultApp, .copyFilePath, .copyRelativeFilePath:
            currentFiles(in: store).map { files in
                guard let path = files.cursor ?? files.selected, !files.root.isEmpty else { return false }

                if !files.filter.isEmpty { return files.matches.contains(path) }
                guard let row = files.rows.first(where: { $0.id == path }) else { return false }

                return self != .openSelectedFile || (!row.entry.isFolder && store.primaryReviewModel != nil)
            } == true

        default: false
        }
    }

    func performInContext(on store: Store) {
        guard store.launcherMode == .palette else { return }

        switch self {
        case .closeTerminal: for tab in terminalTabs(in: store) { store.close(tab.id) }

        case .copyTerminal: terminalView(in: store)?.copy(nil)

        case .pasteTerminal: terminalView(in: store)?.paste(nil)

        case .selectAllInTerminal: terminalView(in: store)?.selectAll(nil)

        case .nextTab, .previousTab: store.cycleTab(by: self == .nextTab ? 1 : -1)

        case .pinSession: for id in sessionIDs(in: store) { store.pin(id) }

        case .unpinSession: for id in sessionIDs(in: store) { store.unpin(id) }

        case .snoozeHour, .snoozeTomorrow, .snoozeUntilNeeded:
            let snooze: SessionSnooze = if self == .snoozeHour {
                .until(.now.addingTimeInterval(3600))
            } else if self == .snoozeTomorrow {
                .until(SessionTriage.tomorrowMorning(after: .now))
            } else {
                .needsYou
            }
            for id in sessionIDs(in: store) { store.snooze(id, snooze) }

        case .unsnoozeSession: for id in sessionIDs(in: store) { store.unsnooze(id) }

        case .unloadSession: for tab in sessionTabs(in: store) { store.close(tab.id) }

        case .reopenSession: for id in sessionIDs(in: store) { store.unarchive(id) }

        case .copySessionID: if let id = sessionIDs(in: store).first { copyToPasteboard(id) }

        case .markSessionRead: for id in sessionIDs(in: store) { store.markRead(id) }

        case .markSessionUnread: for id in sessionIDs(in: store) { store.markUnread(id) }

        case .stopWatchingSession:
            let ids = sessionIDs(in: store)
            Task {
                for id in ids {
                    if case let .refused(message) = await store.stopWatching(id) { store.stopWatchingFailure = message }
                }
            }

        case .newTaskFromSessions: store.newTask(from: sessionIDs(in: store))

        case .removeSessionFromTask: for id in sessionIDs(in: store) { store.removeFromTask(id) }

        case .reopenSessionTask: for id in sessionIDs(in: store) { store.markTaskNotDone(containing: id) }

        case .acceptTaskSuggestion, .dismissTaskSuggestion:
            if let id = sessionIDs(in: store).first, let suggestion = store.taskSuggestions[id] {
                if self == .acceptTaskSuggestion { store.accept(suggestion) } else { store.dismiss(suggestion) }
            }

        case .stopConversation: if let id = store.mainTabID { store.conversationModels[id]?.interrupt() }

        case .closeSubagentConversation: if let id = store.mainTabID { store.conversationModels[id]?.openSubagent = nil }

        case .findInReview, .refreshReview, .toggleReviewTree, .toggleReviewComments, .collapseAllComments, .expandAllComments, .clearReviewMarks, .sendReviewComments, .closeReviewTab, .closeOtherReviewTabs,
             .closeReviewPreview, .revealReviewFile, .copyReviewPath, .copyReviewRelativePath, .openReviewFile,
             .stopBrowserLoading, .copyBrowserURL, .openInDefaultBrowser,
             .toggleIgnoredFiles, .clearFilesFilter, .openSelectedFile, .revealSelectedFile, .openFileInDefaultApp, .copyFilePath, .copyRelativeFilePath:
            performInReviewBrowserOrFiles(on: store)

        case .commandPalette, .filterSidebar, .newSession, .pullRequests, .showPullRequestInReview, .searchSessions,
             .newTerminal, .newTerminalForSession, .switchTerminal, .findInTerminal, .clearTerminal, .archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession,
             .groupBy, .showTriage, .hideTriage, .newGroup, .collapseAllGroups, .expandAllGroups, .showStats, .harbor,
             .showChanges, .hideChanges, .showChangesPane, .showFilesPane, .showTasksPane, .showBrowser,
             .openLocation, .newBrowserTab, .closeBrowserTab, .reopenBrowserTab, .reloadPage, .browserBack, .browserForward, .showWebInspector,
             .openPreview, .showSideBySide, .showInline, .wrapLines, .showRenderedMarkdown, .showMarkdownSource,
             .showClaudeBelow, .showClaudeBeside, .showConversation, .showTerminal,
             .save, .settings, .checkForUpdates, .goBack, .goForward, .previousChange, .nextChange, .caret:
            break
        }
    }

    private func performInReviewBrowserOrFiles(on store: Store) {
        switch self {
        case .findInReview:
            guard let textView = store.paletteResponder as? ReviewTextView else { return }

            store.launcherMode = nil
            DispatchQueue.main.async {
                guard store.launcherMode == nil, let window = textView.window else { return }

                window.makeFirstResponder(textView)
                Self.showReviewFind(in: textView)
            }

        case .refreshReview: Task { await store.refreshReview() }

        case .toggleReviewTree: UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: ReviewModel.changesAsTreeKey), forKey: ReviewModel.changesAsTreeKey)

        case .toggleReviewComments: store.primaryReviewModel?.showsCommentList.toggle()

        case .collapseAllComments, .expandAllComments: store.reviewModel?.commentCollapse.set(all: self == .collapseAllComments)

        case .clearReviewMarks: store.clearReviewMarks()

        case .sendReviewComments:
            if let id = store.selectedSessionID, let model = store.primaryReviewModel {
                Task { await store.sendReviewComments(sessionID: id, model: model) }
            }

        case .closeReviewTab: store.closeDiff()

        case .closeOtherReviewTabs:
            if let model = store.reviewModel, let selected = model.selectedTabID {
                for tab in model.tabs where tab.id != selected {
                    store.clearReviewMarks(path: tab.document.path)
                    model.close(tab.id)
                }
            }

        case .closeReviewPreview: store.reviewModel?.closePreview()

        case .revealReviewFile: store.reviewModel?.filesReveal = store.reviewModel?.selectedDocument?.path

        case .copyReviewPath: if let path = reviewFilePath(in: store) { copyToPasteboard(path) }

        case .copyReviewRelativePath: if let path = store.reviewModel?.selectedDocument?.path { copyToPasteboard(path) }

        case .openReviewFile:
            if let model = store.reviewModel, let document = model.selectedDocument {
                model.open(ReviewDocument(path: document.path, compare: nil, root: document.root))
            }

        case .stopBrowserLoading: store.browser.shownTab?.loadedWebView?.stopLoading()

        case .copyBrowserURL: if let url = store.browser.shownTab?.url { copyToPasteboard(url.absoluteString) }

        case .openInDefaultBrowser: if let url = store.browser.shownTab?.url { store.browser.openOutside(url) }

        case .toggleIgnoredFiles: currentFiles(in: store)?.showsIgnored.toggle()

        case .clearFilesFilter: currentFiles(in: store)?.filter = ""

        case .openSelectedFile, .revealSelectedFile, .openFileInDefaultApp, .copyFilePath, .copyRelativeFilePath:
            guard let files = currentFiles(in: store), let path = files.cursor ?? files.selected else { return }

            let url = URL(filePath: files.root).appending(path: path)
            if self == .revealSelectedFile { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            if self == .openFileInDefaultApp { NSWorkspace.shared.open(url) }
            if self == .copyFilePath { copyToPasteboard(url.path) }
            if self == .copyRelativeFilePath { copyToPasteboard(path) }
            if self == .openSelectedFile, let review = store.primaryReviewModel {
                store.openFile(path, in: files, review: review)
                review.focusesEditor = true
            }

        default: break
        }
    }

    private static func showReviewFind(in textView: ReviewTextView) {
        if textView.selectedRanges.count == 1, textView.selectedRange().length > 0,
           textView.textStorage?.mutableString.rangeOfCharacter(from: .newlines, options: [], range: textView.selectedRange()).location == NSNotFound {
            let setSearchString = NSMenuItem()
            setSearchString.tag = NSTextFinder.Action.setSearchString.rawValue
            textView.performTextFinderAction(setSearchString)
        }
        let showFindInterface = NSMenuItem()
        showFindInterface.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(showFindInterface)
    }

    private func reviewFilePath(in store: Store) -> String? {
        guard let model = store.reviewModel, let document = model.selectedDocument, !document.path.isEmpty,
              let root = document.root ?? model.changes?.root else { return nil }

        return (root as NSString).appendingPathComponent(document.path)
    }

    private func hasReviewTreeChanges(in store: Store) -> Bool {
        store.sessionReviewModels.contains { model in
            model.changes.map { !$0.uncommitted.isEmpty || !$0.committed.isEmpty } == true
        } || store.selectedSessionID.flatMap { store.editedFiles[$0]?.isEmpty } == false
    }
}
