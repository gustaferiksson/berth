import SwiftUI

struct RestartBanner: View {
    let version: String
    let deadline: Date
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 16) {
            TimelineView(.periodic(from: deadline - AppUpdater.restartDelay, by: 1)) { context in
                let seconds = max(1, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("Berth will restart to install version \(version) in ^[\(seconds) second](inflect: true)")
                    .monospacedDigit()
            }
            Button("Not Now", action: store.updater.postpone)
                .buttonStyle(.borderless)
                .focusable(false)
            Button("Restart Now", action: store.updater.installAndRelaunch)
                .buttonStyle(.borderedProminent)
                .focusable(false)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(16)
    }
}
