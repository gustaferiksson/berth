import AppKit
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
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Terminal Panel") { appDelegate.store.toggleTerminalPanel() }
                    .keyboardShortcut("j")
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
            guard event.window?.identifier?.rawValue.hasPrefix("main") == true,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            else { return event }
            if event.charactersIgnoringModifiers == "j" {
                store.toggleTerminalPanel()
                return nil
            }
            if event.charactersIgnoringModifiers == "t" {
                store.openShell(cwd: store.currentCwd)
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
