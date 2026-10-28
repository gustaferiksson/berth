import SwiftUI

@main
struct BerthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Berth", id: "main") {
            ContentView()
                .environment(appDelegate.store)
        }
        .defaultSize(width: 1200, height: 760)
        .defaultLaunchBehavior(Snapshot.output == nil ? .presented : .suppressed)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Claude Session") { appDelegate.store.openClaude(cwd: appDelegate.store.currentCwd) }
                    .keyboardShortcut("n")
                Button("New Terminal") { appDelegate.store.openShell(cwd: appDelegate.store.currentCwd) }
                    .keyboardShortcut("t")
            }
            CommandGroup(after: .sidebar) {
                Button(appDelegate.store.isPanelOpen ? "Hide Terminal Panel" : "Show Terminal Panel") { appDelegate.store.toggleTerminalPanel() }
                    .keyboardShortcut("j")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
