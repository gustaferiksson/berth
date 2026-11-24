import BerthCore
import Foundation
import GhosttyTerminal

@Observable
final class ControlService {
    static let enabledKey = "controlEnabled"
    static let directory = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.gustaf.berth").appending(path: "control").path
    static let cliTool = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "berth-cli")

    private static let exitsDirectory = directory + "/exits"

    private(set) var failure: String?
    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var openedBy: [UUID: UUID] = [:]

    init(store: Store) {
        self.store = store
    }

    func update() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return stop() }
        guard server == nil else { return }

        try? ControlInstall.refreshInstalled(skillFile: ControlInstaller.skillFile, settingsFile: ControlInstaller.settingsFile)
        do {
            let token = try ControlEnvironment.persistentToken(directory: Self.directory)
            try? FileManager.default.removeItem(atPath: Self.exitsDirectory)
            let server = ControlServer(path: ControlEnvironment.socketPath(directory: Self.directory), token: token) { [weak self] request in
                await self?.handle(request) ?? .failure("Berth is quitting")
            }
            try server.start()
            self.token = token
            self.server = server
            failure = nil
        } catch {
            failure = "Couldn’t listen for the berth command: \(error)"
        }
    }

    func environment(for tab: UUID) -> [String: String] {
        guard server != nil else { return [:] }

        return ControlEnvironment.variables(socketPath: ControlEnvironment.socketPath(directory: Self.directory), token: token, tab: tab.uuidString)
    }

    private func stop() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: Self.directory + "/token")
        failure = nil
        openedBy = [:]
    }

    private func handle(_ request: ControlRequest) async -> ControlResponse {
        guard let caller = UUID(uuidString: request.caller), store.tabs.contains(where: { $0.id == caller }) else { return .failure("Unknown calling tab") }

        if request.operation == .list { return list(for: caller) }

        if request.operation == .open || request.operation == .openSession { return open(request, for: caller) }

        if request.operation == .openPath { return openPath(request, for: caller) }

        guard let tab = request.tab else { return .failure("Missing tab") }

        let matches = store.tabs.filter { $0.id.uuidString.lowercased().hasPrefix(tab.lowercased()) }
        guard matches.count == 1, let target = matches.first else { return .failure(matches.isEmpty ? "No tab \(tab)" : "\(tab) matches more than one tab") }

        switch request.operation {
        case .capture: return await capture(target)

        case .wait: return await wait(for: target.id, timeout: request.timeout)

        default: break
        }
        guard openedBy[target.id] == caller else { return .failure("You can only send to or close tabs you opened") }

        if request.operation == .close {
            store.close(target.id)
            return ControlResponse()
        }

        store.lastKeyInput = .now
        guard target.terminal.paste(text: request.text ?? "") else { return .failure("The tab didn’t accept the text") }

        if request.enter != false { target.terminal.sendKey(.enter) }

        return ControlResponse()
    }

    private func list(for caller: UUID) -> ControlResponse {
        ControlResponse(tabs: store.tabs.map { tab in
            ControlTab(
                id: Self.shortID(tab.id),
                kind: tab.kind.rawValue,
                title: tab.title(terminalTitle: tab.terminal.title, sessionTitle: store.sessionTitle(of: tab)),
                cwd: tab.folder,
                session: tab.sessionID,
                status: tab.sessionID.flatMap { store.liveBySession[$0]?.status },
                openedByYou: openedBy[tab.id] == caller
            )
        })
    }

    private func open(_ request: ControlRequest, for caller: UUID) -> ControlResponse {
        let cwd = request.cwd ?? store.tabs.first { $0.id == caller }?.folder ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return .failure("No folder \(cwd)") }

        let id: UUID
        let previous = store.selectedTabID
        if request.operation == .openSession {
            guard let opened = store.openSession(cwd: cwd, checkout: .main, pasting: request.text, selectsTab: request.background != true) else { return .failure("Couldn’t open a Claude session in \(cwd)") }

            id = opened
        } else {
            id = UUID()
            let command = request.command.map { ControlExitStatus.wrapping($0, recordingIn: Self.exitsDirectory + "/" + id.uuidString) }
            try? FileManager.default.createDirectory(atPath: Self.exitsDirectory, withIntermediateDirectories: true)
            let callerTab = store.tabs.first { $0.id == caller }
            let parent = callerTab?.kind == .claude ? callerTab?.id : callerTab?.parentTabID
            store.openShell(cwd: cwd, command: command, id: id, parent: parent)
        }
        openedBy = openedBy.filter { opened in store.tabs.contains { $0.id == opened.key } }
        openedBy[id] = caller
        if request.background != true {
            store.activate(.tab(id))
        } else if request.operation == .open {
            store.selectedTabID = previous
        }
        return ControlResponse(tab: Self.shortID(id))
    }

    private func openPath(_ request: ControlRequest, for caller: UUID) -> ControlResponse {
        guard let path = request.path, path.hasPrefix("/") else { return .failure("Missing absolute path") }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .failure("No such path \(path)") }
        guard isDirectory.boolValue else { return .failure("\(path) is a file, and Berth opens folders only") }

        let id: UUID
        if let shown = store.tabs.first(where: { $0.kind == .claude && $0.folder == path }) {
            id = shown.id
        } else {
            guard let opened = store.openSession(cwd: path, checkout: .main, selectsTab: false) else { return .failure("Couldn’t open a Claude session in \(path)") }

            id = opened
            openedBy = openedBy.filter { opened in store.tabs.contains { $0.id == opened.key } }
            openedBy[id] = caller
        }
        if request.background != true { store.activate(.tab(id)) }
        return ControlResponse(tab: Self.shortID(id))
    }

    private func capture(_ tab: Tab) async -> ControlResponse {
        guard tab.isHosted, let socket = store.hostSocket(of: tab.id) else {
            return .failure("Capture is unsupported for this tab: Berth can only read tabs opened with Keep sessions running when Berth quits on")
        }
        guard let bytes = await Task.detached(operation: { SessionHost.dump(socketPath: socket) }).value else { return .failure("The tab’s session host didn’t answer") }

        return ControlResponse(text: TerminalText.plain(bytes))
    }

    private func wait(for id: UUID, timeout: Double?) async -> ControlResponse {
        let file = Self.exitsDirectory + "/" + id.uuidString
        let deadline = timeout.map { Date.now.addingTimeInterval($0) }
        while store.tabs.contains(where: { $0.id == id }), !FileManager.default.fileExists(atPath: file) {
            if let deadline, Date.now > deadline { return .failure("Timed out") }

            try? await Task.sleep(for: .milliseconds(200))
        }
        defer { try? FileManager.default.removeItem(atPath: file) }

        guard let status = (try? String(contentsOfFile: file, encoding: .utf8)).flatMap({ Int32($0) }) else { return .failure("The tab closed without an exit status") }

        return ControlResponse(exit: status)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}
