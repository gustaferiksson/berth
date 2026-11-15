import BerthCore
import Foundation
import GhosttyTerminal
import Network
import Observation

final class RemoteServer {
    static let enabledKey = "remoteEnabled"
    static let tokenKey = "remoteToken"
    static let port: UInt16 = 7878

    private struct Client {
        let connection: NWConnection
        var isAuthenticated = false
        var sessionID: String?
        var transcript: URL?
        var end: Int?
    }

    private unowned let store: Store
    private var listener: NWListener?
    private var watcher: FileWatcher?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var lastSessions: Data?

    init(store: Store) {
        self.store = store
    }

    func update() {
        let token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), !token.isEmpty else { return stop() }
        guard listener == nil else { return }

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 1 << 20
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }

        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case let .failed(error) = state else { return }
            MainActor.assumeIsolated {
                print("remote: listener failed: \(error)")
                self?.stop()
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        watcher = FileWatcher(paths: [Store.claudeDirectory.appending(path: "projects").path], latency: 0.3) { [weak self] _ in self?.streamTranscripts() }
        observeSessions()
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        watcher = nil
        lastSessions = nil
        for client in clients.values { client.connection.cancel() }
        clients = [:]
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        clients[id] = Client(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state { connection.cancel() }
                if case .cancelled = state { self?.clients[id] = nil }
            }
        }
        connection.start(queue: .main)
        receive(on: connection)
        Task {
            try? await Task.sleep(for: .seconds(10))
            if clients[id]?.isAuthenticated == false { connection.cancel() }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, error == nil, let data, !data.isEmpty, self.clients[ObjectIdentifier(connection)] != nil else { return connection.cancel() }
                self.handle(data, from: connection)
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let client = clients[id], let message = try? JSONDecoder().decode(RemoteClientMessage.self, from: data) else { return connection.cancel() }

        guard client.isAuthenticated else {
            let token = Array((UserDefaults.standard.string(forKey: Self.tokenKey) ?? "").utf8)
            guard case let .hello(offered) = message, Array(offered.utf8).count == token.count, zip(offered.utf8, token).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return connection.cancel() }
            clients[id]?.isAuthenticated = true
            return send(try? JSONEncoder().encode(sessionsMessage), to: connection)
        }

        switch message {
        case .hello:
            return
        case let .subscribe(sessionID):
            clients[id]?.sessionID = sessionID
            clients[id]?.transcript = nil
            clients[id]?.end = nil
            streamTranscripts()
        case let .prompt(sessionID, text):
            Task { await submit(text, in: sessionID, from: connection) }
        case let .key(sessionID, key):
            press(key, in: sessionID, from: connection)
        case let .newSession(folder, prompt):
            Task { await startSession(in: folder, prompt: prompt, from: connection) }
        }
    }

    private var sessionsMessage: RemoteServerMessage {
        let open = Set(store.tabs.compactMap(\.sessionID))
        let remote = { (session: SessionSummary) in
            let live = self.store.liveBySession[session.id]
            return RemoteSession(
                id: session.id,
                title: session.title,
                folder: session.cwd,
                branch: session.branch,
                lastActivity: session.lastActivity,
                status: live?.status,
                waitingFor: live?.waitingFor,
                isOpen: open.contains(session.id),
                isLocked: live.map { $0.attachID == nil } ?? false && !open.contains(session.id)
            )
        }
        let starting = store.tabs.filter { $0.kind == .claude && $0.sessionID.map { store.sessionsByID[$0] == nil } ?? false }.compactMap { tab in
            tab.sessionID.map { RemoteSession(id: $0, title: "New Session", folder: tab.cwd, branch: nil, lastActivity: tab.opened, status: store.liveBySession[$0]?.status, waitingFor: store.liveBySession[$0]?.waitingFor, isOpen: true, isLocked: false) }
        }
        let groups = [RemoteGroup(id: "starting", title: "New", sessions: starting), RemoteGroup(id: "pinned", title: "Pinned", sessions: store.pinnedSessions.map(remote))]
            + store.groups.map { RemoteGroup(id: $0.id, title: $0.title, sessions: $0.sessions.map(remote)) }
        return .sessions(groups: groups.filter { !$0.sessions.isEmpty }, folders: store.knownFolders.prefix(30).map(\.path))
    }

    private func observeSessions() {
        guard listener != nil else { return }

        let data = withObservationTracking {
            try? JSONEncoder().encode(sessionsMessage)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSessions() }
        }
        guard let data, data != lastSessions else { return }

        lastSessions = data
        for client in clients.values where client.isAuthenticated { send(data, to: client.connection) }
        streamTranscripts()
    }

    private func streamTranscripts() {
        for (id, client) in clients {
            guard let sessionID = client.sessionID else { continue }
            guard let url = store.index.url(ofSession: sessionID) else {
                if client.end == nil { send(try? JSONEncoder().encode(RemoteServerMessage.transcript(sessionID: sessionID, entries: [], isContinuation: false)), to: client.connection) }
                clients[id]?.end = 0
                continue
            }
            let after = url == client.transcript ? client.end : nil
            guard let chunk = TranscriptTail.read(url, after: after) else { continue }

            clients[id]?.transcript = url
            clients[id]?.end = chunk.end
            guard !chunk.isContinuation || !chunk.entries.isEmpty else { continue }
            send(try? JSONEncoder().encode(RemoteServerMessage.transcript(sessionID: sessionID, entries: chunk.entries, isContinuation: chunk.isContinuation)), to: client.connection)
        }
    }

    private func submit(_ text: String, in sessionID: String, from connection: NWConnection) async {
        guard store.sessionsByID[sessionID] != nil || store.tab(forSession: sessionID) != nil else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Unknown session")), to: connection) }

        if store.tab(forSession: sessionID) == nil || store.liveBySession[sessionID] == nil {
            if let live = store.liveBySession[sessionID], live.attachID == nil, store.tab(forSession: sessionID) == nil {
                return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "This session is running in another terminal, so it is read-only here")), to: connection)
            }
            store.activate(.session(sessionID))
            let deadline = Date.now + 30
            while Date.now < deadline, store.tab(forSession: sessionID) == nil || store.liveBySession[sessionID] == nil {
                try? await Task.sleep(for: .milliseconds(250))
                store.refreshLive()
            }
            try? await Task.sleep(for: .seconds(2))
        }

        guard let terminal = store.tab(forSession: sessionID)?.terminal, store.liveBySession[sessionID] != nil else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude didn’t start for this session")), to: connection) }
        store.lastKeyInput = .now
        terminal.paste(text: text)
        terminal.sendKey(.enter)
    }

    private func press(_ key: RemoteKey, in sessionID: String, from connection: NWConnection) {
        guard let terminal = store.tab(forSession: sessionID)?.terminal, store.liveBySession[sessionID] != nil else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude isn’t running in a Berth tab for this session")), to: connection) }

        store.lastKeyInput = .now
        let press = switch key {
        case .enter: TerminalKeyPress(.enter)
        case .escape: TerminalKeyPress(.escape)
        case .shiftTab: TerminalKeyPress(.tab, modifiers: .shift)
        case .digit1: TerminalKeyPress(.digit1)
        case .digit2: TerminalKeyPress(.digit2)
        case .digit3: TerminalKeyPress(.digit3)
        case .digit4: TerminalKeyPress(.digit4)
        case .digit5: TerminalKeyPress(.digit5)
        case .digit6: TerminalKeyPress(.digit6)
        case .digit7: TerminalKeyPress(.digit7)
        case .digit8: TerminalKeyPress(.digit8)
        case .digit9: TerminalKeyPress(.digit9)
        }
        terminal.sendKey(press)
    }

    private func startSession(in folder: String, prompt: String, from connection: NWConnection) async {
        guard store.knownFolders.contains(where: { $0.path == folder }), FileManager.default.fileExists(atPath: folder) else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Unknown folder")), to: connection) }

        store.openClaude(cwd: folder)
        guard let sessionID = store.tabs.first(where: { $0.id == store.selectedTabID })?.sessionID else { return }
        send(try? JSONEncoder().encode(RemoteServerMessage.opened(sessionID: sessionID)), to: connection)
        guard !prompt.isEmpty else { return }
        await submit(prompt, in: sessionID, from: connection)
    }

    private func send(_ data: Data?, to connection: NWConnection) {
        guard let data else { return }
        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
