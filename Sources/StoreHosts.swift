import BerthCore
import Foundation

extension Store {
    static let hostsDirectory = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.gustaf.berth").appending(path: "hosts").path

    #if DEBUG
    private static let isHostingAllowed = (Snapshot.output == nil && SettingsSnapshot.output == nil) || UserDefaults.standard.string(forKey: "snapshotHost") != nil
    #else
    private static let isHostingAllowed = true
    #endif

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

    func refreshHostedDirectories() async {
        let sockets = tabs.compactMap { tab in tab.kind == .shell && tab.isHosted ? hostSocket(of: tab.id).map { (tab.id, $0) } : nil }
        guard !sockets.isEmpty else { return }

        let directories = await Task.detached {
            sockets.compactMap { id, socket in
                SessionHost.probe(socketPath: socket).flatMap { ProcessAncestry.workingDirectory(of: $0.child) }.map { (id, $0) }
            }
        }.value
        for (id, directory) in directories {
            guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].cwd != directory else { continue }

            tabs[index].cwd = directory
        }
    }

    func hangUpHost(of id: UUID) {
        guard let socket = hostSocket(of: id) else { return }

        Task.detached { SessionHost.hangUp(socketPath: socket) }
    }
}
