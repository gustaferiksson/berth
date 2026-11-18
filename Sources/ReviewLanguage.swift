import BerthCore
import Foundation

@Observable
final class ReviewLanguage {
    private struct Key: Hashable {
        let server: LanguageServerEntry
        let folder: String
    }

    private struct Running {
        let server: LanguageServer
        let startedAt: ContinuousClock.Instant
    }

    let root: String
    private var published: [Key: [String: [LanguageServerDiagnostic]]] = [:]
    @ObservationIgnored private var servers: [Key: Task<Running?, Never>] = [:]
    @ObservationIgnored private var sent: [Key: [String: String]] = [:]
    @ObservationIgnored private var generation = 0

    init(root: String) {
        self.root = root
    }

    func diagnostics(for path: String) -> [LanguageServerDiagnostic] {
        let file = URL(filePath: root).appending(path: path).resolvingSymlinksInPath().path
        return published.sorted { $0.key.server.id < $1.key.server.id }.flatMap { $0.value[file] ?? [] }
    }

    func sync(_ path: String, text: String) async {
        guard UserDefaults.standard.bool(forKey: GeneralSettings.languageServersKey) else { return }

        let configured = LanguageServerEntry.configured(UserDefaults.standard.string(forKey: LanguageServerEntry.storageKey)).filter(\.isEnabled)
        for key in servers.keys where !configured.contains(key.server) {
            let task = servers.removeValue(forKey: key)
            Task { await task?.value?.server.stop() }
            sent[key] = nil
            published[key] = nil
        }

        let keys = keys(for: path, among: configured)
        for key in keys where servers[key] == nil { servers[key] = start(key) }
        for key in keys { _ = await send(path, text: text, to: key) }
    }

    func hover(_ path: String, text: String, at position: LanguageServerPosition) async -> String? {
        let url = URL(filePath: root).appending(path: path)
        return await ask(path, text: text) { try await $0.hover(in: url, at: position)?.markdown }
    }

    func definition(_ path: String, text: String, at position: LanguageServerPosition) async -> LanguageServerLocation? {
        let url = URL(filePath: root).appending(path: path)
        return await ask(path, text: text) { try await $0.definition(in: url, at: position).first }
    }

    func stop() {
        generation += 1
        for task in servers.values {
            Task { await task.value?.server.stop() }
        }
        servers = [:]
        sent = [:]
        published = [:]
    }

    private func keys(for path: String, among configured: [LanguageServerEntry]) -> [Key] {
        configured.filter { $0.serves(path) }.compactMap { server in
            LanguageServers.root(forFile: path, server: server, repositoryRoot: root).map { Key(server: server, folder: $0) }
        }
    }

    private func start(_ key: Key) -> Task<Running?, Never> {
        let generation = generation
        return Task { [weak self] in
            guard let command = LanguageServers.command(for: key.server, root: key.folder) else { return nil }

            let server = LanguageServer(command: command, root: key.folder)
            let isStarted = (try? await server.start()) != nil
            guard isStarted, let self, self.generation == generation else {
                await server.stop()
                if !isStarted, self?.generation == generation { self?.servers[key] = nil }
                return nil
            }

            Task { [weak self] in
                for await update in server.diagnostics where self?.servers[key] != nil {
                    self?.published[key, default: [:]][update.url.resolvingSymlinksInPath().path] = update.diagnostics.map { diagnostic in
                        var labelled = diagnostic
                        labelled.source = diagnostic.source ?? key.server.name
                        return labelled
                    }
                }
                await self?.exited(server, key: key)
            }
            return Running(server: server, startedAt: .now)
        }
    }

    private func exited(_ server: LanguageServer, key: Key) async {
        guard let task = servers[key], await task.value?.server === server else { return }

        servers[key] = nil
        sent[key] = nil
    }

    private func send(_ path: String, text: String, to key: Key) async -> Running? {
        guard let running = await servers[key]?.value else { return nil }

        if sent[key]?[path] != text {
            sent[key, default: [:]][path] = text
            try? await running.server.open(URL(filePath: root).appending(path: path), languageID: LanguageServers.languageID(forFile: path), text: text)
        }
        return running
    }

    private func ask<Answer>(_ path: String, text: String, _ question: (LanguageServer) async throws -> Answer?) async -> Answer? {
        let configured = LanguageServerEntry.configured(UserDefaults.standard.string(forKey: LanguageServerEntry.storageKey)).filter { $0.isEnabled && !$0.isDiagnosticsOnly }

        for key in keys(for: path, among: configured) {
            guard let running = await send(path, text: text, to: key) else { continue }

            attempts: for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                guard !Task.isCancelled else { return nil }

                do {
                    if let answer = try await question(running.server) { return answer }
                    guard ContinuousClock.now - running.startedAt < .seconds(10) else { break attempts }
                } catch let LanguageServerError.response(code, _) where code == -32801 {
                    continue
                } catch {
                    break attempts
                }
            }
        }
        return nil
    }
}
