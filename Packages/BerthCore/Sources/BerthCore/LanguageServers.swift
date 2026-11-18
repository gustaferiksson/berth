import Foundation

public struct LanguageServerCommand: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct LanguageServerEntry: Codable, Hashable, Identifiable, Sendable {
    public static let storageKey = "languageServers"
    public static let defaults = [
        LanguageServerEntry(id: "sourcekit-lsp", name: "SourceKit-LSP", command: "sourcekit-lsp", languages: ["swift"], rootMarkers: ["Package.swift"]),
        LanguageServerEntry(id: "rust-analyzer", name: "rust-analyzer", command: "rust-analyzer", languages: ["rust"]),
        LanguageServerEntry(id: "typescript-language-server", name: "TypeScript", command: "typescript-language-server", arguments: ["--stdio"], languages: ["typescript", "typescriptreact", "javascript", "javascriptreact"]),
    ]

    public var id: String
    public var name: String
    public var command: String
    public var arguments: [String]
    public var languages: [String]
    public var rootMarkers: [String]
    public var settings: String?
    public var isDiagnosticsOnly: Bool
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, command: String, arguments: [String] = [], languages: [String] = [], rootMarkers: [String] = [], settings: String? = nil, isDiagnosticsOnly: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.languages = languages
        self.rootMarkers = rootMarkers
        self.settings = settings
        self.isDiagnosticsOnly = isDiagnosticsOnly
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        languages = try container.decode([String].self, forKey: .languages)
        rootMarkers = try container.decodeIfPresent([String].self, forKey: .rootMarkers) ?? []
        settings = try container.decodeIfPresent(String.self, forKey: .settings)
        isDiagnosticsOnly = try container.decodeIfPresent(Bool.self, forKey: .isDiagnosticsOnly) ?? false
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public static func stored(_ json: String?) -> (entries: [LanguageServerEntry], unreadable: [String]) {
        guard let json, !json.isEmpty else { return ([], []) }

        let fragment = { (value: Any) in (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed) else { return ([], fragment(json).map { [$0] } ?? []) }
        guard let elements = parsed as? [Any] else { return ([], fragment(parsed).map { [$0] } ?? []) }

        let fragments = elements.compactMap(fragment)
        let decoded = fragments.map { (fragment: $0, entry: try? JSONDecoder().decode(LanguageServerEntry.self, from: Data($0.utf8))) }
        return (decoded.compactMap(\.entry), decoded.filter { $0.entry == nil }.map(\.fragment))
    }

    public static func configured(_ json: String?) -> [LanguageServerEntry] {
        let stored = stored(json).entries
        return stored + defaults.filter { entry in !stored.contains { $0.id == entry.id } }
    }

    public static func storage(_ entries: [LanguageServerEntry], keeping unreadable: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let readable = entries.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
        return "[" + (readable + unreadable).joined(separator: ",") + "]"
    }

    public func serves(_ path: String) -> Bool {
        let fileExtension = URL(filePath: path).pathExtension.lowercased()
        return languages.contains { $0 == fileExtension || $0 == LanguageServers.languageID(forFile: path) }
    }
}

public enum LanguageServers {
    private static let languageIDs = [
        "swift": "swift", "rs": "rust",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
    ]

    public static func languageID(forFile path: String) -> String {
        let fileExtension = URL(filePath: path).pathExtension.lowercased()
        return languageIDs[fileExtension] ?? fileExtension
    }

    public static func root(forFile path: String, server: LanguageServerEntry, repositoryRoot: String) -> String? {
        guard !server.rootMarkers.isEmpty else { return repositoryRoot }

        let repository = URL(filePath: repositoryRoot, directoryHint: .isDirectory).standardizedFileURL.path
        let folders = sequence(first: URL(filePath: repositoryRoot).appending(path: path).deletingLastPathComponent().standardizedFileURL) { folder in
            folder.path.count > repository.count ? folder.deletingLastPathComponent() : nil
        }
        return folders.first { folder in server.rootMarkers.contains { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) } }?.path
    }

    public static func command(for server: LanguageServerEntry, root: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> LanguageServerCommand? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let zed = "\(home)/Library/Application Support/Zed"
        let fallbacks = [
            "sourcekit-lsp": ["/usr/bin/sourcekit-lsp"],
            "rust-analyzer": ["\(home)/.cargo/bin/rust-analyzer", "\(home)/.rustup/toolchains/*/bin/rust-analyzer", "\(home)/.vscode/extensions/*/server/rust-analyzer"],
            "typescript-language-server": ["\(zed)/languages/typescript-language-server/node_modules/.bin/typescript-language-server"],
            "node": ["\(home)/.nvm/versions/node/*/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "\(zed)/node/*/bin/node"],
        ]

        let command = server.command.hasPrefix("~/") ? home + server.command.dropFirst() : server.command
        let candidates = command.hasPrefix("/") ? [command]
            : ["\(root)/node_modules/.bin/\(command)"] + path.map { "\($0)/\(command)" } + (fallbacks[command] ?? []) + ["/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"]
        guard let executable = firstExecutable(candidates) else { return nil }

        let head = (try? FileHandle(forReadingFrom: URL(filePath: executable)).read(upToCount: 128)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard head.hasPrefix("#!"), head.prefix(while: { $0 != "\n" }).contains("node") else { return LanguageServerCommand(executable: executable, arguments: server.arguments) }

        guard let node = firstExecutable(path.map { "\($0)/node" } + (fallbacks["node"] ?? [])) else { return nil }
        return LanguageServerCommand(executable: node, arguments: [executable] + server.arguments)
    }

    private static func firstExecutable(_ patterns: [String]) -> String? {
        let fileManager = FileManager.default
        let candidates = patterns.flatMap { pattern -> [String] in
            guard let wildcard = pattern.range(of: "/*/") else { return [pattern] }
            let folder = String(pattern[..<wildcard.lowerBound])
            let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
            return names.sorted { $0.localizedStandardCompare($1) == .orderedDescending }.map { "\(folder)/\($0)/\(pattern[wildcard.upperBound...])" }
        }

        return candidates.first { candidate in
            guard fileManager.isExecutableFile(atPath: candidate) else { return false }
            let resolved = URL(filePath: candidate).resolvingSymlinksInPath()
            let fileNumber = (try? fileManager.attributesOfItem(atPath: resolved.path))?[.systemFileNumber] as? Int
            let isRustupProxy = ["rustup", "rustup-init"].contains { name in
                let rustup = resolved.deletingLastPathComponent().appending(path: name).path
                return resolved.lastPathComponent == name || (fileNumber != nil && (try? fileManager.attributesOfItem(atPath: rustup))?[.systemFileNumber] as? Int == fileNumber)
            }
            return !isRustupProxy
        }
    }
}
