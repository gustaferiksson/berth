import BerthCore
import Foundation

extension Store {
    static let hostsDirectory = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.gustaf.berth").appending(path: "hosts").path

    private static let isHostingAllowed = (Snapshot.output == nil && SettingsSnapshot.output == nil) || UserDefaults.standard.string(forKey: "snapshotHost") != nil

    private static var hostTool: String? {
        let tool = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "berth-host").path
        return tool.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    func hostLaunch(_ command: String?, id: UUID) -> (command: String?, isHosted: Bool) {
        guard UserDefaults.standard.bool(forKey: GeneralSettings.keepsSessionsRunningKey), let tool = Self.hostTool, hostSocket(of: id) != nil else { return (command, false) }

        return (SessionHost.newCommand(tool: tool, directory: Self.hostsDirectory, id: id.uuidString, command: command ?? "/bin/zsh -il"), true)
    }

    func hostSocket(of id: UUID) -> String? {
        guard Self.isHostingAllowed else { return nil }

        return try? SessionHost.socketPath(directory: Self.hostsDirectory, id: id.uuidString)
    }

    func attachCommand(of id: UUID) -> String? {
        guard hostSocket(of: id) != nil else { return nil }

        return Self.hostTool.map { SessionHost.attachCommand(tool: $0, directory: Self.hostsDirectory, id: id.uuidString) }
    }

    func hangUpHost(of id: UUID) {
        guard let socket = hostSocket(of: id) else { return }

        Task.detached { SessionHost.hangUp(socketPath: socket) }
    }
}
