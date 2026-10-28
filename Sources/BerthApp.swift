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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let output = Snapshot.output else { return }
        Task { await Snapshot.capture(to: output, store: store) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
