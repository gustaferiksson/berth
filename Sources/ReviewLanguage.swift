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

    func hover(_ path: String, text: String, base: ReviewLanguageBase? = nil, at position: LanguageServerPosition) async -> String? {
        await ask(path, text: text, base: base) { try await $0.hover(in: $1, at: position)?.markdown }
    }

    func definition(_ path: String, text: String, base: ReviewLanguageBase? = nil, at position: LanguageServerPosition) async -> LanguageServerLocation? {
        await ask(path, text: text, base: base) { try await $0.definition(in: $1, at: position).first }
    }

    func references(_ path: String, text: String, base: ReviewLanguageBase? = nil, at position: LanguageServerPosition) async -> [LanguageServerLocation]? {
        await ask(path, text: text, base: base) { server, url in
            let references = try await server.references(in: url, at: position)
            return references.isEmpty ? nil : references
        }
    }

    func base(of path: String, text: String) -> ReviewLanguageBase {
        let url = URL(filePath: root).appending(path: path)
        return ReviewLanguageBase(url: url.deletingLastPathComponent().appending(path: ".berth-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"), text: text)
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

            let server = LanguageServer(command: command, root: key.folder, settings: key.server.settings)
            let isStarted = (try? await server.start()) != nil
            guard isStarted, let self, self.generation == generation else {
                await server.stop()
                if !isStarted, self?.generation == generation { self?.servers[key] = nil }
                return nil
            }

            Task { [weak self] in
                for await update in server.diagnostics where self?.servers[key] != nil && !update.url.lastPathComponent.hasPrefix(".berth-") {
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

    private func ask<Answer>(_ path: String, text: String, base: ReviewLanguageBase?, _ question: (LanguageServer, URL) async throws -> Answer?) async -> Answer? {
        let configured = LanguageServerEntry.configured(UserDefaults.standard.string(forKey: LanguageServerEntry.storageKey)).filter { $0.isEnabled && !$0.isDiagnosticsOnly }
        let url = base?.url ?? URL(filePath: root).appending(path: path)

        for key in keys(for: path, among: configured) {
            guard let running = await send(path, text: text, to: key) else { continue }

            if let base { try? await running.server.open(base.url, languageID: LanguageServers.languageID(forFile: path), text: base.text) }
            var answer: Answer?
            attempts: for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                guard !Task.isCancelled else { break attempts }

                do {
                    answer = try await question(running.server, url)
                    if answer != nil || ContinuousClock.now - running.startedAt >= .seconds(10) { break attempts }
                } catch let LanguageServerError.response(code, _) where code == -32801 {
                    continue
                } catch {
                    break attempts
                }
            }
            if base != nil { try? await running.server.close(url) }
            if answer != nil || Task.isCancelled { return answer }
        }
        return nil
    }
}

struct ReviewLanguageBase {
    let url: URL
    let text: String
}
