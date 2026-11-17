import BerthCore
import Foundation

@Observable
final class ReviewLanguage {
    private struct Key: Hashable {
        let folder: String
        let languageID: String
    }

    private struct Running {
        let server: LanguageServer
        let startedAt: ContinuousClock.Instant
    }

    let root: String
    private(set) var diagnostics: [String: [LanguageServerDiagnostic]] = [:]
    @ObservationIgnored private var servers: [Key: Task<Running?, Never>] = [:]
    @ObservationIgnored private var sent: [String: String] = [:]
    @ObservationIgnored private var generation = 0

    init(root: String) {
        self.root = root
    }

    func sync(_ path: String, text: String) async {
        guard UserDefaults.standard.bool(forKey: GeneralSettings.languageServersKey), let key = key(for: path) else { return }

        if servers[key] == nil { servers[key] = start(key) }
        _ = await send(path, text: text, to: key)
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
        diagnostics = [:]
    }

    private func key(for path: String) -> Key? {
        guard let languageID = LanguageServers.languageID(forFile: path), let folder = LanguageServers.root(forFile: path, languageID: languageID, repositoryRoot: root) else { return nil }
        return Key(folder: folder, languageID: languageID)
    }

    private func start(_ key: Key) -> Task<Running?, Never> {
        let generation = generation
        return Task { [weak self] in
            guard let command = LanguageServers.command(forLanguage: key.languageID, root: key.folder) else { return nil }

            let server = LanguageServer(command: command, root: key.folder)
            let isStarted = (try? await server.start()) != nil
            guard isStarted, let self, self.generation == generation else {
                await server.stop()
                if !isStarted, self?.generation == generation { self?.servers[key] = nil }
                return nil
            }

            Task { [weak self] in
                for await published in server.diagnostics {
                    self?.diagnostics[published.url.resolvingSymlinksInPath().path] = published.diagnostics
                }
                await self?.exited(server, key: key)
            }
            return Running(server: server, startedAt: .now)
        }
    }

    private func exited(_ server: LanguageServer, key: Key) async {
        guard let task = servers[key], await task.value?.server === server else { return }

        servers[key] = nil
        sent = sent.filter { self.key(for: $0.key) != key }
    }

    private func send(_ path: String, text: String, to key: Key) async -> Running? {
        guard let running = await servers[key]?.value else { return nil }

        if sent[path] != text {
            sent[path] = text
            try? await running.server.open(URL(filePath: root).appending(path: path), languageID: key.languageID, text: text)
        }
        return running
    }

    private func ask<Answer>(_ path: String, text: String, _ question: (LanguageServer) async throws -> Answer?) async -> Answer? {
        guard let key = key(for: path), let running = await send(path, text: text, to: key) else { return nil }

        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return nil }

            do {
                if let answer = try await question(running.server) { return answer }
                guard ContinuousClock.now - running.startedAt < .seconds(10) else { return nil }
            } catch let LanguageServerError.response(code, _) where code == -32801 {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}
