import AppKit
import BerthCore
import SwiftUI

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
                Button("New Claude Session") { appDelegate.store.openClaude(cwd: appDelegate.store.currentCwd) }
                    .keyboardShortcut("n")
                Button("New Terminal") { appDelegate.store.openShell(cwd: appDelegate.store.currentCwd) }
                    .keyboardShortcut("t")
                Button("New Group…") { appDelegate.store.editingGroup = CustomGroup(name: "", rules: []) }
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
                Button("Toggle Terminal Panel") { appDelegate.store.toggleTerminalPanel() }
                    .keyboardShortcut("j")
                Divider()
                Menu("Group By") { GroupingMenuItems(store: appDelegate.store) }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()

    private var keyMonitor: Any?

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
            guard flags == .command else { return event }
            if event.charactersIgnoringModifiers == "j" {
                store.toggleTerminalPanel()
                return nil
            }
            if event.charactersIgnoringModifiers == "t" {
                store.openShell(cwd: store.currentCwd)
                return nil
            }
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
