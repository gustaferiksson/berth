import AppKit
import BerthCore
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

    init() {
        guard Snapshot.output != nil, UserDefaults.standard.string(forKey: "snapshotReview") != nil else { return }
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
                ForEach([AppAction.newSession, .searchSessions, .newTerminal, .newGroup], id: \.self) { $0.menuButton(appDelegate.store) }
            }
            CommandGroup(before: .saveItem) {
                if isReviewEnabled {
                    SaveMenuItem(store: appDelegate.store)
                }
            }
            CommandGroup(after: .pasteboard) {
                AppAction.findInTerminal.menuButton(appDelegate.store)
                AppAction.clearTerminal.menuButton(appDelegate.store)
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
                Divider()
                Menu("Group By") { GroupingMenuItems(store: appDelegate.store) }
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

    var body: some View {
        (AppAction.hideChanges.isAvailable(in: store) ? AppAction.hideChanges : .showChanges).menuButton(store)
        let layout = AppAction.showInline.isAvailable(in: store) ? AppAction.showInline : .showSideBySide
        layout.menuButton(store)
            .disabled(!layout.isAvailable(in: store))
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Snapshot.output != nil || settingsSnapshot != nil else { return }
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Rows draw their own grey selection and hover; AppKit's blue context-menu ring has no public switch.
        if let method = class_getInstanceMethod(NSTableView.self, NSSelectorFromString("drawContextMenuHighlightForRow:")) {
            let noHighlight: @convention(block) (NSTableView, Int) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(noHighlight))
        }

        #if DEBUG
        if let output = SettingsSnapshot.output {
            Task { await SettingsSnapshot.capture(to: output) }
            return
        }
        #endif
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
            guard event.window?.identifier?.rawValue.hasPrefix("main") == true else { return event }
            store.lastKeyInput = .now
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let isTab = event.keyCode == 48
            if flags == [.command, .shift], event.keyCode == 30 || event.keyCode == 33 {
                store.cycleTab(by: event.keyCode == 30 ? 1 : -1)
                return nil
            }
            if isTab, flags == .control || flags == [.control, .shift] {
                store.cycleTab(by: flags.contains(.shift) ? -1 : 1)
                return nil
            }
            let responder = event.window?.firstResponder as? NSView
            let ancestors = responder.map { Array(sequence(first: $0, next: \.superview)) } ?? []
            if flags == .command, event.charactersIgnoringModifiers == "f", ancestors.contains(where: { $0 is NSHostingView<ReviewDiffColumn> }) {
                let showFindInterface = NSMenuItem()
                showFindInterface.tag = NSTextFinder.Action.showFindInterface.rawValue
                ancestors.lazy.compactMap { $0 as? ReviewTextView }.first?.performTextFinderAction(showFindInterface)
                return nil
            }
            if flags == .command, event.charactersIgnoringModifiers == "w", store.reviewModel?.selectedTab != nil, !store.tabs.contains(where: { $0.terminal.attachedPlatformView === responder }) {
                store.closeDiff()
                return nil
            }
            let modifiers = EventModifiers([(NSEvent.ModifierFlags.command, EventModifiers.command), (.shift, .shift), (.option, .option), (.control, .control)].filter { flags.contains($0.0) }.map(\.1))
            if let action = AppAction.routedPastTerminal.first(where: { $0.shortcut?.modifiers == modifiers && $0.shortcut.map { String($0.key.character) } == event.charactersIgnoringModifiers?.lowercased() && (![.showChanges, .hideChanges, .findInTerminal, .save].contains($0) || $0.isAvailable(in: store)) }) {
                action.perform(on: store)
                return nil
            }
            if store.terminalSearch != nil, event.keyCode == 5, flags == .command || flags == [.command, .shift] {
                store.focusedTerminal?.performBindingAction(flags.contains(.shift) ? "navigate_search:previous" : "navigate_search:next")
                return nil
            }
            guard flags == .command else { return event }
            if let number = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(number) {
                store.selectTab(number: number)
                return nil
            }
            return event
        }
        for key in ProcessInfo.processInfo.environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") {
            unsetenv(key)
        }
        guard let output = Snapshot.output else {
            UNUserNotificationCenter.current().delegate = self
            store.start(restoringTabs: true)
            store.updater.start()
            store.remote.update()
            return
        }
        store.persistsTabs = false
        store.start(restoringTabs: false)
        Task { await Snapshot.capture(to: output, store: store) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveOpenTabs()
        ProcessAncestry.hangUpDescendants()
        store.updater.installOnQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
