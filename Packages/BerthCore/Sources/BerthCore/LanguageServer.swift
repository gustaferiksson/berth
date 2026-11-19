import Foundation

public struct LanguageServerPosition: Sendable, Hashable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LanguageServerRange: Sendable, Hashable {
    public let start: LanguageServerPosition
    public let end: LanguageServerPosition

    public init(start: LanguageServerPosition, end: LanguageServerPosition) {
        self.start = start
        self.end = end
    }

    init?(json: Any?) {
        guard let range = json as? [String: Any],
              let start = range["start"] as? [String: Any], let startLine = start["line"] as? Int, let startCharacter = start["character"] as? Int,
              let end = range["end"] as? [String: Any], let endLine = end["line"] as? Int, let endCharacter = end["character"] as? Int
        else { return nil }

        self.start = LanguageServerPosition(line: startLine, character: startCharacter)
        self.end = LanguageServerPosition(line: endLine, character: endCharacter)
    }
}

public struct LanguageServerLocation: Sendable, Hashable {
    public let url: URL
    public let range: LanguageServerRange

    public init(url: URL, range: LanguageServerRange) {
        self.url = url
        self.range = range
    }
}

public struct LanguageServerHover: Sendable, Hashable {
    public let markdown: String
    public let range: LanguageServerRange?
}

public struct LanguageServerDiagnostic: Sendable, Hashable {
    public enum Severity: Int, Sendable {
        case error = 1
        case warning
        case information
        case hint
    }

    public let range: LanguageServerRange
    public let severity: Severity?
    public let message: String
    public var source: String?
}

public struct LanguageServerDiagnostics: Sendable, Hashable {
    public let url: URL
    public let version: Int?
    public let diagnostics: [LanguageServerDiagnostic]
}

public enum LanguageServerError: Error, Equatable {
    case notRunning
    case response(code: Int, message: String)
}

struct LanguageServerFraming {
    private static let separator = Data("\r\n\r\n".utf8)
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []

        while let separator = buffer.firstRange(of: Self.separator) {
            let header = String(decoding: buffer[buffer.startIndex..<separator.lowerBound], as: UTF8.self)
            let length = header.split(separator: "\r\n").compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }

                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first

            guard let length else {
                buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
                continue
            }
            guard buffer.endIndex - separator.upperBound >= length else { break }

            let end = separator.upperBound + length
            messages.append(Data(buffer[separator.upperBound..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return messages
    }
}

public actor LanguageServer {
    private static let shutdownTimeout: Duration = .seconds(2)

    public nonisolated let diagnostics: AsyncStream<LanguageServerDiagnostics>
    private let diagnosticsContinuation: AsyncStream<LanguageServerDiagnostics>.Continuation
    private let command: LanguageServerCommand
    private let root: URL
    private let settings: Any?
    private let process = Process()
    private let input = Pipe()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var versions: [URL: Int] = [:]
    private var hasExited = false
    private var pullsDiagnostics = false

    public init(command: LanguageServerCommand, root: String, settings: String? = nil) {
        let stream = AsyncStream.makeStream(of: LanguageServerDiagnostics.self)
        diagnostics = stream.stream
        diagnosticsContinuation = stream.continuation
        self.command = command
        self.root = URL(filePath: root, directoryHint: .isDirectory)
        self.settings = settings.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    public func start() async throws {
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(filePath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        let messages = AsyncStream.makeStream(of: Data.self)
        let outputHandle = output.fileHandleForReading
        let errorHandle = errors.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            var framing = LanguageServerFraming()
            while case let chunk = outputHandle.availableData, !chunk.isEmpty {
                for message in framing.append(chunk) { messages.continuation.yield(message) }
            }
            messages.continuation.finish()
        }
        DispatchQueue.global(qos: .utility).async {
            while !errorHandle.availableData.isEmpty {}
        }
        Task { [weak self] in
            for await message in messages.stream { await self?.receive(message) }
            await self?.exited()
        }

        let capabilities: [String: Any] = [
            "general": ["positionEncodings": ["utf-16"]],
            "textDocument": [
                "synchronization": ["dynamicRegistration": false],
                "definition": ["linkSupport": true],
                "references": ["dynamicRegistration": false],
                "hover": ["contentFormat": ["markdown", "plaintext"]],
                "publishDiagnostics": ["versionSupport": true],
            ],
            "workspace": ["configuration": settings != nil],
        ]
        let initialized = try await request("initialize", [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "Berth"],
            "rootUri": root.absoluteString,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
            "capabilities": capabilities,
        ])
        pullsDiagnostics = ((initialized as? [String: Any])?["capabilities"] as? [String: Any])?["diagnosticProvider"] != nil
        try send(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
        if let settings { try send(["jsonrpc": "2.0", "method": "workspace/didChangeConfiguration", "params": ["settings": settings]]) }
    }

    public func open(_ url: URL, languageID: String, text: String) throws {
        guard versions[url] == nil else { return try change(url, text: text) }

        versions[url] = 1
        try send([
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": ["textDocument": ["uri": url.absoluteString, "languageId": languageID, "version": 1, "text": text]],
        ])
        if pullsDiagnostics { Task { await pullDiagnostics(url) } }
    }

    public func change(_ url: URL, text: String) throws {
        guard let version = versions[url].map({ $0 + 1 }) else { return }

        versions[url] = version
        try send([
            "jsonrpc": "2.0",
            "method": "textDocument/didChange",
            "params": ["textDocument": ["uri": url.absoluteString, "version": version], "contentChanges": [["text": text]]],
        ])
        if pullsDiagnostics { Task { await pullDiagnostics(url) } }
    }

    public func close(_ url: URL) throws {
        guard versions.removeValue(forKey: url) != nil else { return }

        try send(["jsonrpc": "2.0", "method": "textDocument/didClose", "params": ["textDocument": ["uri": url.absoluteString]]])
    }

    public func definition(in url: URL, at position: LanguageServerPosition) async throws -> [LanguageServerLocation] {
        let result = try await request("textDocument/definition", [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
        ])

        let items = result as? [[String: Any]] ?? (result as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { item in
            guard let uri = (item["targetUri"] ?? item["uri"]) as? String, let url = URL(string: uri),
                  let range = LanguageServerRange(json: item["targetSelectionRange"] ?? item["range"])
            else { return nil }

            return LanguageServerLocation(url: url, range: range)
        }
    }

    public func references(in url: URL, at position: LanguageServerPosition) async throws -> [LanguageServerLocation] {
        let result = try await request("textDocument/references", [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
            "context": ["includeDeclaration": true],
        ])

        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let uri = item["uri"] as? String, let url = URL(string: uri), let range = LanguageServerRange(json: item["range"]) else { return nil }

            return LanguageServerLocation(url: url, range: range)
        }
    }

    public func hover(in url: URL, at position: LanguageServerPosition) async throws -> LanguageServerHover? {
        let result = try await request("textDocument/hover", [
            "textDocument": ["uri": url.absoluteString],
            "position": ["line": position.line, "character": position.character],
        ])
        guard let hover = result as? [String: Any], let contents = hover["contents"] else { return nil }

        let markdown = (contents as? [Any] ?? [contents]).compactMap { piece -> String? in
            if let text = piece as? String { return text }
            guard let object = piece as? [String: Any], let value = object["value"] as? String else { return nil }
            guard let language = object["language"] as? String else { return value }

            return "```\(language)\n\(value)\n```"
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }

        return LanguageServerHover(markdown: markdown, range: LanguageServerRange(json: hover["range"]))
    }

    public func stop() async {
        guard !hasExited, process.isRunning else { return }

        let deadline = ContinuousClock.now + Self.shutdownTimeout
        let shutdown = Task { _ = try? await request("shutdown", nil) }
        let timeout = Task {
            try await Task.sleep(until: deadline)
            shutdown.cancel()
        }
        await shutdown.value
        timeout.cancel()

        try? send(["jsonrpc": "2.0", "method": "exit"])
        let exitDeadline = max(deadline, ContinuousClock.now + .milliseconds(500))
        while process.isRunning, ContinuousClock.now < exitDeadline { try? await Task.sleep(for: .milliseconds(50)) }
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        exited()
    }

    private func pullDiagnostics(_ url: URL) async {
        let version = versions[url]
        let report = try? await request("textDocument/diagnostic", ["textDocument": ["uri": url.absoluteString]]) as? [String: Any]
        guard let items = report?["items"], versions[url] == version else { return }

        publishDiagnostics(["uri": url.absoluteString, "version": version as Any, "diagnostics": items])
    }

    private func request(_ method: String, _ params: Any?) async throws -> Any? {
        guard !hasExited else { throw LanguageServerError.notRunning }

        nextID += 1
        let id = nextID
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params ?? NSNull()])
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }

        let object = try JSONSerialization.jsonObject(with: response) as? [String: Any]
        if let error = object?["error"] as? [String: Any] {
            throw LanguageServerError.response(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "")
        }
        return object?["result"]
    }

    private func cancel(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }

        continuation.resume(throwing: CancellationError())
        try? send(["jsonrpc": "2.0", "method": "$/cancelRequest", "params": ["id": id]])
    }

    private func send(_ message: [String: Any]) throws {
        guard !hasExited else { throw LanguageServerError.notRunning }

        let body = try JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
        try input.fileHandleForWriting.write(contentsOf: Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
    }

    private func receive(_ message: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else { return }

        let method = object["method"] as? String

        if let method, let id = object["id"] {
            return respond(to: method, id: id, params: object["params"] as? [String: Any])
        }

        if method == "textDocument/publishDiagnostics" {
            return publishDiagnostics(object["params"] as? [String: Any])
        }

        guard method == nil, let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }

        continuation.resume(returning: message)
    }

    private func respond(to method: String, id: Any, params: [String: Any]?) {
        if method == "workspace/configuration" {
            let items = params?["items"] as? [[String: Any]] ?? []
            let sections = items.map { item in
                (item["section"] as? String ?? "").split(separator: ".").reduce(settings) { ($0 as? [String: Any])?[String($1)] } ?? NSNull()
            }
            try? send(["jsonrpc": "2.0", "id": id, "result": sections])
            return
        }

        if method.hasSuffix("/refresh") || ["client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create"].contains(method) {
            try? send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            return
        }

        try? send(["jsonrpc": "2.0", "id": id, "error": ["code": -32_601, "message": "Method not found: \(method)"]])
    }

    private func publishDiagnostics(_ params: [String: Any]?) {
        guard let uri = params?["uri"] as? String, let url = URL(string: uri) else { return }

        let diagnostics = (params?["diagnostics"] as? [[String: Any]] ?? []).compactMap { diagnostic -> LanguageServerDiagnostic? in
            guard let range = LanguageServerRange(json: diagnostic["range"]), let message = diagnostic["message"] as? String else { return nil }

            let severity = (diagnostic["severity"] as? Int).flatMap(LanguageServerDiagnostic.Severity.init(rawValue:))
            return LanguageServerDiagnostic(range: range, severity: severity, message: message, source: diagnostic["source"] as? String)
        }
        diagnosticsContinuation.yield(LanguageServerDiagnostics(url: url, version: params?["version"] as? Int, diagnostics: diagnostics))
    }

    private func exited() {
        hasExited = true
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: LanguageServerError.notRunning) }
        diagnosticsContinuation.finish()
    }
}
