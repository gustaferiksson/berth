import AppKit
import BerthCore
import CryptoKit
import Foundation
import GhosttyTerminal
import Network
import Observation

@Observable
final class RemoteServer {
    static let enabledKey = "remoteEnabled"
    static let tokenKey = "remoteToken"

    #if DEBUG
    static let port = UInt16(UserDefaults.standard.string(forKey: "snapshotRemotePort") ?? "") ?? 7878
    #else
    static let port: UInt16 = 7878
    #endif

    private struct Client {
        let connection: NWConnection
        let nonce: Data
        var isAuthenticated = false
        var sessionID: String?
        var transcript: URL?
        var end: Int?
        var queue: [String] = []
        var activity = TranscriptActivity()
        var agentLogs: [String: AgentLog] = [:]
        var sentActivity: RemoteActivity?
        var isReading = false
        var needsRead = false
        var searchQuery: String?
    }

    private struct Upload {
        let file: URL
        let owner: ObjectIdentifier
        var size = 0
        var isComplete = false
    }

    static let uploadsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "\(Bundle.main.bundleIdentifier ?? "dev.gustaf.berth")/RemoteUploads")

    private(set) var failure: String?
    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var clients: [ObjectIdentifier: Client] = [:]
    @ObservationIgnored private var lastSessions: Data?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var submitting: Set<String> = []
    @ObservationIgnored private var uploads: [String: Upload] = [:]
    @ObservationIgnored private var reviewChanges: [String: ReviewChanges] = [:]
    @ObservationIgnored private let imageCache = NSCache<NSString, NSData>()
    @ObservationIgnored private var imageLines: [String: [String: Range<Int>]] = [:]
    @ObservationIgnored private var imageLoads: [String: Task<Data?, Never>] = [:]
    @ObservationIgnored private var pullRequestLoads: [String: (task: Task<PullRequestDetail?, Never>, date: Date)] = [:]

    init(store: Store) {
        self.store = store
        imageCache.totalCostLimit = 64 << 20
    }

    func update() {
        let token = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), !token.isEmpty else { return stop() }

        if token != self.token {
            for client in clients.values { client.connection.cancel() }
            self.token = token
        }
        guard listener == nil else { return }

        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 1 << 20
        websocket.setClientRequestHandler(.main) { _, headers in
            NWProtocolWebSocket.Response(status: headers.contains { $0.name.caseInsensitiveCompare("Origin") == .orderedSame } ? .reject : .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            failure = "Couldn’t listen on port \(Self.port): \(error)"
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    self?.failure = nil

                case let .failed(error), let .waiting(error):
                    print("remote: listener failed: \(error)")
                    self?.stop()
                    self?.failure = "Couldn’t listen on port \(Self.port): \(error)"

                default:
                    break
                }
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
        failure = nil
        for client in clients.values { client.connection.cancel() }
        clients = [:]
    }

    private func accept(_ connection: NWConnection) {
        guard clients.values.count(where: { !$0.isAuthenticated }) < 4 else { return connection.cancel() }

        let id = ObjectIdentifier(connection)
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        clients[id] = Client(connection: connection, nonce: nonce)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed = state { connection.cancel() }
                if case .cancelled = state {
                    self?.clients[id] = nil
                    for (upload, entry) in self?.uploads ?? [:] where entry.owner == id && !entry.isComplete { self?.discardUpload(upload) }
                }
            }
        }
        connection.start(queue: .main)
        send(try? JSONEncoder().encode(RemoteServerMessage.challenge(nonce: nonce)), to: connection)
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
        guard let client = clients[id] else { return connection.cancel() }
        guard client.isAuthenticated else {
            guard !token.isEmpty, data.count <= 256,
                  case let .auth(hmac)? = try? JSONDecoder().decode(RemoteClientMessage.self, from: data),
                  HMAC<SHA256>.isValidAuthenticationCode(hmac, authenticating: client.nonce, using: SymmetricKey(data: Data(token.utf8)))
            else {
                let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
                metadata.closeCode = .protocolCode(.policyViolation)
                return connection.send(content: nil, contentContext: NWConnection.ContentContext(identifier: "close", metadata: [metadata]), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }

            clients[id]?.isAuthenticated = true
            return send(try? JSONEncoder().encode(sessionsMessage), to: connection)
        }
        guard let message = try? JSONDecoder().decode(RemoteClientMessage.self, from: data) else { return connection.cancel() }

        switch message {
        case .auth:
            return

        case let .subscribe(sessionID):
            clients[id]?.sessionID = sessionID
            clients[id]?.transcript = nil
            clients[id]?.end = nil
            Task { await streamTranscript(to: id) }

        case let .prompt(sessionID, text, attachments):
            Task { await submit(text, attachments: attachments ?? [], in: sessionID, from: connection) }

        case let .key(sessionID, key, waitingFor, waitingSince):
            press(key, in: sessionID, answering: waitingFor, since: waitingSince, from: connection)

        case let .newSession(folder, prompt):
            Task { await startSession(in: folder, prompt: prompt, from: connection) }

        case let .session(sessionID, action):
            perform(action, on: sessionID, from: connection)

        case .refresh:
            store.refresh()
            store.refreshPullRequests()
            send(try? JSONEncoder().encode(sessionsMessage), to: connection)

        case let .upload(uploadID, name, offset, chunk, isLast):
            receiveUpload(uploadID, name: name, offset: offset, chunk: chunk, isLast: isLast, from: connection)

        case let .pullRequest(sessionID):
            Task { await sendPullRequest(of: sessionID, to: connection) }

        case let .search(query):
            Task { await search(query, for: id) }

        case let .changes(sessionID):
            Task { await sendChanges(of: sessionID, to: connection) }

        case .usage:
            Task {
                await store.refreshPlanUsage()
                send(try? JSONEncoder().encode(RemoteServerMessage.usage(store.planUsage)), to: connection)
            }

        case let .changeDiff(sessionID, path, isCommitted):
            Task { await sendChangeDiff(of: path, isCommitted: isCommitted, in: sessionID, to: connection) }

        case let .taskDetail(sessionID, taskID):
            Task { await sendTaskDetail(taskID, in: sessionID, to: id) }

        case let .image(sessionID, imageID, variant):
            Task { await sendImage(imageID, variant: variant, in: sessionID, to: connection) }
        }
    }

    private func sendImage(_ imageID: String, variant: RemoteImageVariant, in sessionID: String, to connection: NWConnection) async {
        let reply = { (data: Data?) in self.send(try? JSONEncoder().encode(RemoteServerMessage.image(sessionID: sessionID, id: imageID, variant: variant, data: data)), to: connection) }
        guard let url = store.index.url(ofSession: sessionID) else { return reply(nil) }

        let key = "\(sessionID)/\(imageID)/\(variant.rawValue)" as NSString
        if let cached = imageCache.object(forKey: key) { return reply(cached as Data) }

        let line = imageLines[sessionID]?[imageID]
        let load = imageLoads[key as String] ?? Task.detached { TranscriptImages.image(id: imageID, variant: variant, in: url, line: line) }
        imageLoads[key as String] = load
        let data = await load.value
        imageLoads[key as String] = nil
        if let data { imageCache.setObject(data as NSData, forKey: key, cost: data.count) }
        reply(data)
    }

    private func search(_ query: String, for id: ObjectIdentifier) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= RemoteSearchFeature.minimumQueryLength, clients[id] != nil else { return }

        clients[id]?.searchQuery = query
        if store.searchIndexTask == nil { store.updateSearchIndex() }

        while true {
            let index = store.searchIndex
            let sessions = store.activeSessions + store.archivedSessions
            let isIndexing = store.searchIndexing != nil || store.searchIndexVersion == 0
            let found = await Task.detached { index.search(query, in: sessions) }.value
            guard let client = clients[id], client.searchQuery == query else { return }

            let hits = found.map { hit in
                RemoteSearchHit(id: hit.id, title: hit.session.title, folder: hit.session.checkout, lastActivity: hit.session.lastActivity, snippets: hit.snippets.map { snippet in
                    RemoteSnippet(text: snippet.text, highlights: snippet.highlights.map { range in
                        let nsRange = NSRange(range, in: snippet.text)
                        return nsRange.location..<nsRange.location + nsRange.length
                    })
                })
            }
            send(try? JSONEncoder().encode(RemoteServerMessage.searchResults(query: query, hits: hits, isIndexing: isIndexing)), to: client.connection)
            guard isIndexing else { return }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func sendChanges(of sessionID: String, to connection: NWConnection) async {
        let reply = { (changes: RemoteChanges?) in self.send(try? JSONEncoder().encode(RemoteServerMessage.changes(sessionID: sessionID, changes: changes)), to: connection) }
        let folder = store.sessionsByID[sessionID].map { FileManager.default.fileExists(atPath: $0.cwd) ? $0.cwd : $0.checkout } ?? store.tab(forSession: sessionID)?.cwd
        guard let folder else { return reply(nil) }

        let picks = UserDefaults.standard.dictionary(forKey: ReviewModel.baseBranchesKey) as? [String: [String: String]] ?? [:]
        let pullRequest = store.pullRequestTarget(forSession: sessionID)?.pullRequest
        let loaded = await Task.detached {
            try? await ReviewGit.changes(in: folder) { root, branch in (picks[root]?[branch], pullRequest?.headRefName == branch ? pullRequest?.baseRefName : nil) }
        }.value
        guard let loaded else { return reply(nil) }

        reviewChanges[sessionID] = loaded
        reply(RemoteChanges(loaded))
    }

    private func sendChangeDiff(of path: String, isCommitted: Bool, in sessionID: String, to connection: NWConnection) async {
        let reply = { (diff: RemoteFileDiff?) in self.send(try? JSONEncoder().encode(RemoteServerMessage.changeDiff(sessionID: sessionID, path: path, isCommitted: isCommitted, diff: diff)), to: connection) }
        guard let changes = reviewChanges[sessionID], let file = (isCommitted ? changes.committed : changes.uncommitted).first(where: { $0.path == path }) else { return reply(nil) }

        let contents = await Task.detached { try? await ReviewGit.contents(of: file, compare: isCommitted ? .committed : .uncommitted, in: changes) }.value
        reply(contents.map { RemoteFileDiff($0) })
    }

    private func sendPullRequest(of sessionID: String, to connection: NWConnection) async {
        let reply = { (detail: RemotePullRequestDetail?) in self.send(try? JSONEncoder().encode(RemoteServerMessage.pullRequest(sessionID: sessionID, detail: detail)), to: connection) }
        guard let target = store.pullRequestTarget(forSession: sessionID) else { return reply(nil) }

        let key = "\(target.repository)#\(target.pullRequest.number)"
        let cached = pullRequestLoads[key].flatMap { Date.now.timeIntervalSince($0.date) < 60 ? $0 : nil }
        let isSnapshot = Snapshot.output != nil
        let fixture = Snapshot.fixturePullRequestDetail
        let load = cached ?? (task: Task.detached { [repository = target.repository, number = target.pullRequest.number] in
            isSnapshot ? fixture : PullRequestStatus.detail(repository: repository, number: number)
        }, date: Date.now)
        pullRequestLoads[key] = load
        guard let detail = await load.task.value else {
            if pullRequestLoads[key]?.date == load.date { pullRequestLoads[key] = nil }
            return reply(nil)
        }

        let pullRequest = target.pullRequest
        reply(RemotePullRequestDetail(
            number: pullRequest.number,
            title: pullRequest.title,
            state: pullRequest.state.rawValue,
            url: pullRequest.url,
            repository: target.repository,
            head: detail.headRefName,
            base: pullRequest.baseRefName,
            checks: detail.checks?.state.rawValue,
            checksPassed: detail.checks?.passed,
            checksFailed: detail.checks?.failed,
            checksRunning: detail.checks?.running,
            reviewDecision: detail.reviewDecision,
            unresolvedThreads: detail.unresolvedThreads,
            additions: detail.additions,
            deletions: detail.deletions,
            changedFiles: detail.changedFiles,
            commits: detail.commits
        ))
    }

    private func sendTaskDetail(_ taskID: String, in sessionID: String, to id: ObjectIdentifier) async {
        guard let client = clients[id], client.sessionID == sessionID, let transcript = client.transcript else { return }

        let output = client.activity.outputFile(of: taskID)
        var log = client.agentLogs[taskID]
        let detail = await Task.detached {
            if let output { return RemoteTaskDetail(output: TaskOutput.tail(output)) }
            guard log != nil else { return RemoteTaskDetail() }

            log?.read(transcript.deletingPathExtension().appending(path: "subagents/agent-\(taskID).jsonl"))
            return RemoteTaskDetail(calls: log?.calls, reply: log?.reply)
        }.value
        guard let connection = clients[id]?.connection else { return }

        send(try? JSONEncoder().encode(RemoteServerMessage.taskDetail(sessionID: sessionID, taskID: taskID, detail: detail)), to: connection)
    }

    private func receiveUpload(_ uploadID: String, name: String, offset: Int, chunk: Data, isLast: Bool, from connection: NWConnection) {
        let fail = { (message: String) in self.send(try? JSONEncoder().encode(RemoteServerMessage.uploaded(id: uploadID, error: message)), to: connection) }
        guard let id = UUID(uuidString: uploadID)?.uuidString else { return fail("The upload had an invalid id") }

        if offset == 0, uploads[id] == nil {
            guard uploads.values.count(where: { !$0.isComplete }) < 8 else { return fail("Too many uploads at once") }

            let safe = String(name.split(separator: "/").last ?? "").replacing(/[^A-Za-z0-9._-]/, with: "-").drop { $0 == "." || $0 == "-" }
            let cleaned = URL(filePath: safe.isEmpty ? "file" : String(safe))
            let stem = cleaned.deletingPathExtension().lastPathComponent.prefix(90)
            let file = Self.uploadsDirectory.appending(path: id).appending(path: "\(stem)\(cleaned.pathExtension.isEmpty ? "" : ".\(cleaned.pathExtension.prefix(10))")")
            guard (try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                  FileManager.default.createFile(atPath: file.path, contents: nil)
            else { return fail("Berth couldn’t save the file") }

            uploads[id] = Upload(file: file, owner: ObjectIdentifier(connection))
        }

        guard let upload = uploads[id], !upload.isComplete, offset == upload.size, upload.size + chunk.count <= RemoteUpload.maxBytes else {
            discardUpload(id)
            return fail("The upload failed or is over \(RemoteUpload.maxBytes >> 20) MB")
        }

        do {
            let handle = try FileHandle(forWritingTo: upload.file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk)
        } catch {
            discardUpload(id)
            return fail("Berth couldn’t save the file")
        }

        uploads[id]?.size += chunk.count
        uploads[id]?.isComplete = isLast
        guard isLast else { return }

        send(try? JSONEncoder().encode(RemoteServerMessage.uploaded(id: uploadID, error: nil)), to: connection)
    }

    private func discardUpload(_ id: String) {
        guard let upload = uploads.removeValue(forKey: id) else { return }

        try? FileManager.default.removeItem(at: upload.file.deletingLastPathComponent())
    }

    private var sessionsMessage: RemoteServerMessage {
        let open = Set(store.tabs.compactMap(\.sessionID))
        let remote = { (session: SessionSummary) in
            let live = self.store.liveBySession[session.id]
            return RemoteSession(
                id: session.id,
                title: session.title,
                folder: session.checkout,
                branch: session.branch,
                lastActivity: session.lastActivity,
                status: live?.status,
                waitingFor: live?.waitingFor,
                waitingSince: live?.status == "waiting" ? live?.statusUpdatedAt : nil,
                isOpen: open.contains(session.id),
                isLocked: self.store.isLockedElsewhere(live) && !open.contains(session.id),
                lastPrompt: session.lastPrompt,
                pullRequest: self.store.pullRequest(for: session).map { RemotePullRequest(number: $0.number, state: $0.state.rawValue, url: $0.url, checks: $0.checks?.rawValue) },
                isUnread: self.store.isUnread(session),
                turnStartedAt: self.store.turnStarts[session.id]
            )
        }
        let starting = store.tabs.filter { $0.kind == .claude && $0.sessionID.map { store.sessionsByID[$0] == nil } ?? false }.compactMap { tab in
            tab.sessionID.map { RemoteSession(id: $0, title: "New Session", folder: tab.cwd, branch: nil, lastActivity: tab.opened, status: store.liveBySession[$0]?.status, waitingFor: store.liveBySession[$0]?.waitingFor, waitingSince: store.liveBySession[$0].flatMap { $0.status == "waiting" ? $0.statusUpdatedAt : nil }, isOpen: true, isLocked: false) }
        }
        let groups = [RemoteGroup(id: "starting", title: "New", sessions: starting), RemoteGroup(id: "pinned", title: "Pinned", sessions: store.pinnedSessions.map(remote))]
            + store.groups.map { RemoteGroup(id: $0.id, title: $0.title, sessions: $0.sessions.map(remote)) }
        return .sessions(groups: groups.filter { !$0.sessions.isEmpty }, folders: store.knownFolders.prefix(30).map(\.path), features: [RemoteUpload.feature, RemotePullRequestFeature.name, RemoteSearchFeature.name, RemoteChangesFeature.name, RemoteTaskDetail.feature, RemoteImagesFeature.name] + (UserDefaults.standard.bool(forKey: PlanUsageFetch.enabledKey) ? [RemoteUsageFeature.name] : []))
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
        for id in clients.keys { Task { await streamTranscript(to: id) } }
    }

    private func streamTranscript(to id: ObjectIdentifier) async {
        guard let client = clients[id], let sessionID = client.sessionID else { return }
        guard !client.isReading else {
            clients[id]?.needsRead = true
            return
        }
        guard let url = store.index.url(ofSession: sessionID) else {
            if client.end == nil { send(try? JSONEncoder().encode(RemoteServerMessage.transcript(sessionID: sessionID, entries: [], isContinuation: false, queued: [], activity: nil)), to: client.connection) }
            clients[id]?.end = 0
            return
        }

        let after = url == client.transcript ? client.end : nil
        clients[id]?.isReading = true
        clients[id]?.needsRead = false
        let queue = client.queue
        let live = store.liveBySession[sessionID]
        let catalogDirectory = Store.claudeDirectory.appending(path: "cache/model-catalog")
        let previous = url == client.transcript ? client.activity : TranscriptActivity()
        let previousLogs = url == client.transcript ? client.agentLogs : [:]
        let (chunk, activity, logs, report) = await Task.detached {
            let chunk = TranscriptTail.read(url, after: after, queue: queue)
            let result = TranscriptActivity.report(url, previous: previous, logs: previousLogs, live: live, catalogDirectory: catalogDirectory)
            return (chunk, result.activity, result.logs, result.report)
        }.value
        guard let current = clients[id] else { return }

        clients[id]?.isReading = false
        if let chunk, current.sessionID == sessionID, current.transcript == client.transcript, current.end == client.end {
            clients[id]?.transcript = url
            clients[id]?.end = chunk.end
            clients[id]?.queue = chunk.queue
            imageLines[sessionID] = (chunk.isContinuation ? imageLines[sessionID] ?? [:] : [:]).merging(chunk.imageLines) { $1 }
            clients[id]?.activity = activity
            clients[id]?.agentLogs = logs
            clients[id]?.sentActivity = report
            if !chunk.isContinuation || !chunk.entries.isEmpty || chunk.queue != current.queue || report != current.sentActivity {
                send(try? JSONEncoder().encode(RemoteServerMessage.transcript(sessionID: sessionID, entries: chunk.entries, isContinuation: chunk.isContinuation, queued: chunk.queuedPrompts, activity: report)), to: current.connection)
            }
        }
        if current.needsRead { await streamTranscript(to: id) }
    }

    private func submit(_ text: String, attachments: [String], in sessionID: String, from connection: NWConnection) async {
        let files = attachments.compactMap { UUID(uuidString: $0).flatMap { uploads[$0.uuidString] }.flatMap { $0.isComplete ? $0.file : nil } }
        guard files.count == attachments.count else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "An attachment didn’t finish uploading, so the message wasn’t sent")), to: connection) }
        guard !submitting.contains(sessionID) else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "The previous message is still being sent or the session is starting, so this one wasn’t sent")), to: connection) }

        submitting.insert(sessionID)
        defer { submitting.remove(sessionID) }

        guard store.sessionsByID[sessionID] != nil || store.tab(forSession: sessionID) != nil else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Unknown session")), to: connection) }

        store.refreshLive()
        guard store.liveBySession[sessionID]?.status != "waiting" else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude is waiting for an answer, so the message wasn’t sent")), to: connection) }

        if store.tab(forSession: sessionID) == nil || store.liveBySession[sessionID] == nil {
            if store.isLockedElsewhere(store.liveBySession[sessionID]), store.tab(forSession: sessionID) == nil {
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

        store.refreshLive()
        guard let terminal = store.tab(forSession: sessionID)?.terminal, store.liveBySession[sessionID] != nil else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude didn’t start for this session")), to: connection) }

        let images = files.filter { ["jpg", "jpeg", "png", "gif", "webp"].contains($0.pathExtension.lowercased()) }
        let message = (files.filter { !images.contains($0) }.map { "@\($0.path)" } + [text]).filter { !$0.isEmpty }.joined(separator: " ")
        store.lastKeyInput = .now
        for image in images {
            guard isAcceptingInput(sessionID, from: connection) else { return }

            terminal.paste(text: image.path)
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard isAcceptingInput(sessionID, from: connection) else { return }

        terminal.paste(text: images.isEmpty ? message : " \(message)")
        if !images.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        guard isAcceptingInput(sessionID, from: connection) else { return }

        store.lastKeyInput = .now
        terminal.sendKey(.enter)
    }

    private func isAcceptingInput(_ sessionID: String, from connection: NWConnection) -> Bool {
        store.refreshLive()
        guard store.liveBySession[sessionID]?.status == "waiting" else { return true }

        send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude started waiting for an answer, so the message wasn’t sent")), to: connection)
        return false
    }

    private func press(_ key: RemoteKey, in sessionID: String, answering waitingFor: String?, since waitingSince: Double?, from connection: NWConnection) {
        store.refreshLive()
        guard let live = store.liveBySession[sessionID], live.status == "waiting", live.waitingFor == waitingFor, live.statusUpdatedAt == waitingSince else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude’s question changed, so the key wasn’t sent")), to: connection) }
        guard let terminal = store.tab(forSession: sessionID)?.terminal else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude isn’t running in a Berth tab for this session")), to: connection) }

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

    private func perform(_ action: RemoteSessionAction, on sessionID: String, from connection: NWConnection) {
        switch action {
        case .show:
            store.activate(.session(sessionID))
            NSApp.activate()

        case .pin:
            store.pin(sessionID)

        case .unpin:
            store.unpin(sessionID)

        case .markRead:
            store.markRead(sessionID)

        case .markUnread:
            store.markUnread(sessionID)

        case .archive:
            guard store.liveBySession[sessionID] == nil else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude is still running in this session, so it can’t be archived from here")), to: connection) }

            store.archive(sessionID)

        case .interrupt:
            store.refreshLive()
            guard store.liveBySession[sessionID]?.status == "busy", let terminal = store.tab(forSession: sessionID)?.terminal else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Claude isn’t working in a Berth tab for this session")), to: connection) }

            store.lastKeyInput = .now
            terminal.sendKey(TerminalKeyPress(.escape))
        }
    }

    private func startSession(in folder: String, prompt: String, from connection: NWConnection) async {
        guard store.knownFolders.contains(where: { $0.path == folder }), FileManager.default.fileExists(atPath: folder) else { return send(try? JSONEncoder().encode(RemoteServerMessage.notice(message: "Unknown folder")), to: connection) }

        store.openClaude(cwd: folder)
        guard let sessionID = store.tabs.first(where: { $0.id == store.selectedTabID })?.sessionID else { return }

        send(try? JSONEncoder().encode(RemoteServerMessage.opened(sessionID: sessionID)), to: connection)
        guard !prompt.isEmpty else { return }

        await submit(prompt, attachments: [], in: sessionID, from: connection)
    }

    private func send(_ data: Data?, to connection: NWConnection) {
        guard let data else { return }

        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
