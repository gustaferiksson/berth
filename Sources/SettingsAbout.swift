import SwiftUI

struct AboutSettings: View {
    @Environment(Store.self) private var store

    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let updater = store.updater
        VStack(spacing: 6) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Berth")
                .font(.title.bold())
            Text("Version \(version) (\(build))")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("A terminal for your Claude Code sessions.")
                .padding(.top, 6)
            HStack(spacing: 8) {
                if updater.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(updater.status == .checking ? "Checking" : "Downloading")
                }
                if updater.staged != nil {
                    Button("Install and Relaunch", action: updater.installAndRelaunch)
                } else {
                    Button("Check for Updates") { updater.check(.manual) }
                        .disabled(updater.isBusy)
                }
            }
            .padding(.top, 12)
            updateStatus(updater.status)
                .font(.callout)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }

    @ViewBuilder private func updateStatus(_ status: AppUpdater.Status) -> some View {
        if status == .checking {
            Text("Checking for updates…").foregroundStyle(.secondary)
        } else if status == .downloading {
            Text("Downloading the update…").foregroundStyle(.secondary)
        } else if case .upToDate(let version) = status {
            Text("Berth \(version) is the latest version.").foregroundStyle(.secondary)
        } else if case .ready(let version) = status {
            Text("Berth \(version) will be installed when sessions are idle.")
        } else if case .blocked(let message) = status {
            Text(message).foregroundStyle(.orange)
        } else if case .failed(let message) = status {
            Text(message).foregroundStyle(.red)
        } else {
            Text(" ")
        }
    }
}
