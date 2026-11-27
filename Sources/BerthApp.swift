import AppKit
import GhosttyTerminal
import SwiftUI
import UserNotifications

#if DEBUG
private let settingsSnapshot = SettingsSnapshot.output
#else
private let settingsSnapshot: URL? = nil
#endif

@main
struct BerthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false
    @AppStorage(GeneralSettings.conversationKey) private var isConversationEnabled = false

    init() {
        GhosttyConfig.registerBundledFonts()
        // The AutoFill heuristic controller loops in SwiftUI's key-view search and hangs the main thread; macOS 26 reads the first key, macOS 27 the second.
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicControllerEnabled": false, "NSAutoFillHeuristicsEnabled": false])
        UserDefaults.standard.register(defaults: [BrowserModel.developerToolsKey: true])
        // Restyling a SwiftUI List's scroll view afterwards re-tiles it inside a SwiftUI update, which crashes outline lists.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)

        guard Snapshot.output != nil, UserDefaults.standard.string(forKey: "snapshotReview") != nil || UserDefaults.standard.bool(forKey: "snapshotTasksReview") else { return }

        UserDefaults.standard.register(defaults: [GeneralSettings.reviewKey: true])
    }

    var body: some Scene {
        Window("Berth", id: "main") {
            ContentView()
                .environment(appDelegate.store)
        }
        .defaultSize(width: 1200, height: 760)
        .defaultLaunchBehavior(Snapshot.output == nil && settingsSnapshot == nil ? .presented : .suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                AppAction.checkForUpdates.menuButton(appDelegate.store)
            }
            CommandGroup(after: .newItem) {
                ForEach([AppAction.newSession, .pullRequests, .showPullRequestInReview, .searchSessions, .newTerminal, .newTerminalForSession, .newGroup], id: \.self) { action in
                    action.menuButton(appDelegate.store)
                        .disabled(!action.isAvailable(in: appDelegate.store))
                }
            }
            CommandGroup(before: .saveItem) {
                if isReviewEnabled {
                    SaveMenuItem(store: appDelegate.store)
                }
            }
            CommandGroup(after: .pasteboard) {
                AppAction.findInTerminal.menuButton(appDelegate.store)
                AppAction.clearTerminal.menuButton(appDelegate.store)
                if isReviewEnabled {
                    SelectionMenu(store: appDelegate.store)
                }
            }
            CommandGroup(before: .windowList) {
                Button("Show Next Tab") { appDelegate.store.cycleTab(by: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Show Previous Tab") { appDelegate.store.cycleTab(by: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                ForEach(1..<9) { number in
                    Button("Select Tab \(number)") { appDelegate.store.selectTab(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
                Button("Select Last Tab") { appDelegate.store.selectTab(number: 9) }
                    .keyboardShortcut("9")
                Divider()
            }
            CommandGroup(after: .sidebar) {
                AppAction.commandPalette.menuButton(appDelegate.store)
                AppAction.switchTerminal.menuButton(appDelegate.store)
                AppAction.showBrowser.menuButton(appDelegate.store)
                    .disabled(!AppAction.showBrowser.isAvailable(in: appDelegate.store))
                AppAction.showTasksPane.menuButton(appDelegate.store)
                    .disabled(!AppAction.showTasksPane.isAvailable(in: appDelegate.store))
                if isReviewEnabled {
                    AppAction.showChangesPane.menuButton(appDelegate.store)
                        .disabled(!AppAction.showChangesPane.isAvailable(in: appDelegate.store))
                    AppAction.showFilesPane.menuButton(appDelegate.store)
                        .disabled(!AppAction.showFilesPane.isAvailable(in: appDelegate.store))
                }
                if isConversationEnabled {
                    (AppAction.showTerminal.isAvailable(in: appDelegate.store) ? AppAction.showTerminal : .showConversation).menuButton(appDelegate.store)
                        .disabled(!(AppAction.showTerminal.isAvailable(in: appDelegate.store) || AppAction.showConversation.isAvailable(in: appDelegate.store)))
                }
                AppAction.filterSidebar.menuButton(appDelegate.store)
                Divider()
                Menu("Group By") { GroupingMenuItems(store: appDelegate.store) }
                Toggle(AppAction.showTriage.title, isOn: Bindable(appDelegate.store).showsTriage)
                AppAction.collapseAllGroups.menuButton(appDelegate.store)
                AppAction.expandAllGroups.menuButton(appDelegate.store)
                Divider()
                AppAction.showStats.menuButton(appDelegate.store)
                Toggle(AppAction.harbor.title, isOn: Bindable(appDelegate.store).isHarborShown)
                if isReviewEnabled {
                    ChangesMenuItem(store: appDelegate.store)
                }
            }
        }

        Window("Stats", id: "stats") {
            StatsView()
                .environment(appDelegate.store)
        }
        .defaultSize(width: 960, height: 800)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}

private struct ChangesMenuItem: View {
    let store: Store
    @AppStorage(GeneralSettings.terminalBelowKey) private var isTerminalBelow = false
    @AppStorage(ReviewStyle.wrapsLinesKey) private var wrapsLines = false

    var body: some View {
        (AppAction.hideChanges.isAvailable(in: store) ? AppAction.hideChanges : .showChanges).menuButton(store)
        AppAction.openPreview.menuButton(store)
            .disabled(!AppAction.openPreview.isAvailable(in: store))
        let layout = AppAction.showInline.isAvailable(in: store) ? AppAction.showInline : .showSideBySide
        layout.menuButton(store)
            .disabled(!layout.isAvailable(in: store))
        Toggle(AppAction.wrapLines.title, isOn: $wrapsLines)
            .keyboardShortcut(AppAction.wrapLines.shortcut)
            .disabled(!AppAction.wrapLines.isAvailable(in: store))
        let markdown = AppAction.showMarkdownSource.isAvailable(in: store) ? AppAction.showMarkdownSource : .showRenderedMarkdown
        markdown.menuButton(store)
            .disabled(!markdown.isAvailable(in: store))
        let terminalPlacement = isTerminalBelow ? AppAction.showClaudeBeside : .showClaudeBelow
        terminalPlacement.menuButton(store)
            .disabled(!terminalPlacement.isAvailable(in: store))
        ForEach([AppAction.goBack, .goForward, .previousChange, .nextChange], id: \.self) { action in
            action.menuButton(store)
                .disabled(!action.isAvailable(in: store))
        }
    }
}

private struct SelectionMenu: View {
    let store: Store

    var body: some View {
        Menu("Selection") {
            ForEach(AppAction.carets, id: \.self) { action in
                if action == .caret(.collapseCursors) { Divider() }
                action.menuButton(store)
                    .disabled(!action.isAvailable(in: store))
            }
        }
    }
}

private struct SaveMenuItem: View {
    let store: Store

    var body: some View {
        AppAction.save.menuButton(store)
            .disabled(!AppAction.save.isAvailable(in: store))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store.shared

    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_: Notification) {
        guard Snapshot.output != nil || settingsSnapshot != nil else { return }

        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Rows draw their own grey selection and hover; AppKit's blue context-menu ring has no public switch.
        if let method = class_getInstanceMethod(NSTableView.self, NSSelectorFromString("drawContextMenuHighlightForRow:")) {
            let noHighlight: @convention(block) (NSTableView, Int) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(noHighlight))
        }

        #if DEBUG
        if let output = SettingsSnapshot.output {
            store.persistsTabs = false
            Task { await SettingsSnapshot.capture(to: output) }
            return
        }
        #endif
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
            guard event.window?.identifier?.rawValue.hasPrefix("main") == true else { return event }

            store.lastKeyInput = .now
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let isTab = event.keyCode == 48
            let isTabCycle = isTab && (flags == .control || flags == [.control, .shift])
            if isTabCycle, store.launcherMode == .projects {
                store.projects.stepColumn(by: flags.contains(.shift) ? -1 : 1)
                return nil
            }
            let tabNumber = flags == .command ? event.charactersIgnoringModifiers.flatMap(Int.init).flatMap { (1...9).contains($0) ? $0 : nil } : nil
            if flags == [.command, .shift], event.keyCode == 30 || event.keyCode == 33 {
                store.cycleTab(by: event.keyCode == 30 ? 1 : -1)
                return nil
            }
            let modifiers = EventModifiers([(NSEvent.ModifierFlags.command, EventModifiers.command), (.shift, .shift), (.option, .option), (.control, .control)].filter { flags.contains($0.0) }.map(\.1))
            let responder = event.window?.firstResponder as? NSView
            let ancestors = responder.map { Array(sequence(first: $0, next: \.superview)) } ?? []
            if store.shownPane == .browser, ancestors.contains(where: { $0 is NSHostingView<PaneHost> }) {
                if isTabCycle {
                    store.browser.selectTab(offset: flags.contains(.shift) ? -1 : 1)
                    return nil
                }
                if let tabNumber {
                    store.browser.selectTab(number: tabNumber)
                    return nil
                }
            }
            if isTabCycle {
                store.cycleTab(by: flags.contains(.shift) ? -1 : 1)
                return nil
            }
            if flags.contains(.command), let key = [33: "[", 30: "]"][event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased().first, let action = AppAction.browser.first(where: { $0.shortcut?.key.character == key && $0.shortcut?.modifiers == modifiers }), action.isAvailable(in: store) {
                action.perform(on: store)
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers == "f", store.sessionPane == .changes || store.sessionPane == .files, ancestors.contains(where: { $0 is NSHostingView<PaneHost> }) {
                let textView = ancestors.lazy.compactMap { $0 as? ReviewTextView }.first
                if let textView, textView.selectedRanges.count == 1, textView.selectedRange().length > 0, textView.textStorage?.mutableString.rangeOfCharacter(from: .newlines, options: [], range: textView.selectedRange()).location == NSNotFound {
                    let setSearchString = NSMenuItem()
                    setSearchString.tag = NSTextFinder.Action.setSearchString.rawValue
                    textView.performTextFinderAction(setSearchString)
                }
                let showFindInterface = NSMenuItem()
                showFindInterface.tag = NSTextFinder.Action.showFindInterface.rawValue
                textView?.performTextFinderAction(showFindInterface)
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w", !store.tabs.contains(where: { $0.parentTabID != nil && $0.terminal.attachedPlatformView === responder }), AppAction.hideChanges.isAvailable(in: store) || store.reviewModel?.selectedTab != nil && !store.tabs.contains(where: { $0.terminal.attachedPlatformView === responder }) {
                store.closeDiff()
                return nil
            }
            let keys = [event.charactersIgnoringModifiers?.lowercased(), event.characters(byApplyingModifiers: [])]
            if let action = AppAction.routedPastTerminal.first(where: { $0.shortcut?.modifiers == modifiers && keys.contains($0.shortcut.map { String($0.key.character) }) && (!([.showPullRequestInReview, .showChanges, .hideChanges, .showChangesPane, .showFilesPane, .showTasksPane, .wrapLines, .showRenderedMarkdown, .showMarkdownSource, .showConversation, .showTerminal, .findInTerminal, .save, .goBack, .goForward, .previousChange, .nextChange] + AppAction.carets).contains($0) || $0.isAvailable(in: store)) }) {
                action.perform(on: store)
                return nil
            }
            if store.terminalSearch != nil, event.keyCode == 5, flags == .command || flags == [.command, .shift] {
                store.focusedTerminal?.performBindingAction(flags.contains(.shift) ? "navigate_search:previous" : "navigate_search:next")
                return nil
            }
            if let tabNumber {
                store.selectTab(number: tabNumber)
                return nil
            }
            return event
        }
        for key in ProcessInfo.processInfo.environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            unsetenv(key)
        }
        guard let output = Snapshot.output else {
            UNUserNotificationCenter.current().delegate = self
            store.control.update()
            store.start(restoringTabs: true)
            store.updater.start()
            store.remote.update()
            return
        }

        #if DEBUG
        Snapshot.seedConversationFixture()
        #endif
        store.persistsTabs = false
        store.start(restoringTabs: false)
        Task { await Snapshot.capture(to: output, store: store) }
    }

    func application(_: NSApplication, open urls: [URL]) {
        for url in urls { store.openIncomingURL(url) }
    }

    func applicationWillTerminate(_: Notification) {
        store.isTerminating = true
        store.saveOpenTabs()
        ProcessAncestry.hangUpDescendants()
        store.updater.installOnQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}
