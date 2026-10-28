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

    var body: some Scene {
        Window("Berth", id: "main") {
            ContentView()
                .environment(appDelegate.store)
        }
        .defaultSize(width: 1200, height: 760)
        .defaultLaunchBehavior(Snapshot.output == nil && settingsSnapshot == nil ? .presented : .suppressed)
        .commands {
            CommandGroup(after: .newItem) {
                ForEach([AppAction.newSession, .searchSessions, .newTerminal, .newGroup], id: \.self) { $0.menuButton(appDelegate.store) }
            }
            CommandGroup(after: .pasteboard) {
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
                AppAction.toggleTerminalPanel.menuButton(appDelegate.store)
                Divider()
                Menu("Group By") { GroupingMenuItems(store: appDelegate.store) }
                AppAction.collapseAllGroups.menuButton(appDelegate.store)
                AppAction.expandAllGroups.menuButton(appDelegate.store)
                Divider()
                AppAction.showStats.menuButton(appDelegate.store)
                AppAction.harbor.menuButton(appDelegate.store)
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
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()

    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Snapshot.output != nil || settingsSnapshot != nil else { return }
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let output = SettingsSnapshot.output {
            Task { await SettingsSnapshot.capture(to: output) }
            return
        }
        #endif
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [store] event in
            guard event.window?.identifier?.rawValue.hasPrefix("main") == true else { return event }
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
            let modifiers = EventModifiers([(NSEvent.ModifierFlags.command, EventModifiers.command), (.shift, .shift), (.option, .option), (.control, .control)].filter { flags.contains($0.0) }.map(\.1))
            if let action = AppAction.routedPastTerminal.first(where: { $0.shortcut?.modifiers == modifiers && $0.shortcut.map { String($0.key.character) } == event.charactersIgnoringModifiers }) {
                action.perform(on: store)
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
            return
        }
        store.persistsTabs = false
        store.start(restoringTabs: false)
        Task { await Snapshot.capture(to: output, store: store) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessAncestry.hangUpDescendants()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
