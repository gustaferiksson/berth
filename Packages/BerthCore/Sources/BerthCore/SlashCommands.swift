import Foundation

public struct SlashCommand: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let source: String
    public let requiresArguments: Bool
    public let argumentHint: String?

    private init(_ name: String, _ summary: String, source: String = "built-in", requiresArguments: Bool = false, argumentHint: String? = nil) {
        self.name = name
        self.summary = summary
        self.source = source
        self.requiresArguments = requiresArguments
        self.argumentHint = argumentHint
    }

    public init(_ command: RemoteSlashCommand) {
        self.init(command.name, command.summary, source: command.source, requiresArguments: command.requiresArguments, argumentHint: command.argumentHint)
    }

    public static let claudeBuiltIns: [Self] = [
        Self("/add-dir", "Add a working directory", requiresArguments: true, argumentHint: "<path>"),
        Self("/clear", "Start a fresh conversation"),
        Self("/compact", "Summarize the conversation to free up context", argumentHint: "[instructions]"),
        Self("/context", "Show context window usage"),
        Self("/cost", "Show token usage and cost"),
        Self("/init", "Create project instructions in CLAUDE.md"),
        Self("/model", "Change the model for this conversation", requiresArguments: true, argumentHint: "<model>"),
        Self("/review", "Review changes or a pull request"),
        Self("/security-review", "Review changes for security vulnerabilities"),
    ]

    public static let codexBuiltIns: [Self] = [
        Self("/compact", "Summarize the conversation to free up context"),
        Self("/init", "Create project instructions in AGENTS.md"),
        Self("/review", "Review changes with custom instructions", requiresArguments: true, argumentHint: "<instructions>"),
        Self("/status", "Show session settings and usage"),
    ]

    public static func matching(_ query: String, in commands: [Self]) -> [Self] {
        let query = query.hasPrefix("/") ? String(query.dropFirst()) : query
        return commands.compactMap { command -> (command: Self, score: Int)? in
            let name = String(command.name.dropFirst())
            guard let score = FuzzyMatch.score(query, name: name, path: "") else { return nil }

            return (command, score)
        }
        .sorted { $0.score > $1.score }
        .map(\.command)
    }
}

#if os(macOS)
public extension RemoteSlashCommand {
    init(_ command: SlashCommand) {
        self.init(name: command.name, summary: command.summary, source: command.source, requiresArguments: command.requiresArguments, argumentHint: command.argumentHint)
    }
}

public extension SlashCommand {
    static func builtIns(for harness: Harness) -> [Self] {
        harness.agent == .codex ? codexBuiltIns : claudeBuiltIns
    }

    static func load(home: URL, folder: URL?, harness: Harness) -> [Self] {
        var groups = [builtIns(for: harness)]
        if harness.agent == .codex {
            let prompts = home.appending(path: ".codex/prompts")
            groups.append(markdown(in: prompts).compactMap { read($0, source: "user", namespace: "prompts") })
        } else {
            let cwd = folder?.standardizedFileURL
            let root = cwd.flatMap { RepositoryRoot.enclosingRepository($0.path)?.root }
            let user = home.appending(path: ".claude")
            let project = [cwd, root == cwd ? nil : root].compactMap(\.self)
                .flatMap { claudeCommands(in: $0.appending(path: ".claude"), source: "project") }
            groups.append(project)
            groups.append(claudeCommands(in: user, source: "user"))
            groups.append(pluginCommands(in: user, folder: cwd))
        }

        var seen: Set<String> = []
        return groups.flatMap { group in
            group.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
        }
    }

    private struct InstalledPlugins: Decodable {
        struct Install: Decodable {
            let installPath: String
            let projectPath: String?
        }

        let plugins: [String: [Install]]
    }

    private static func pluginCommands(in directory: URL, folder: URL?) -> [Self] {
        guard let data = try? Data(contentsOf: directory.appending(path: "plugins/installed_plugins.json")),
              let manifest = try? JSONDecoder().decode(InstalledPlugins.self, from: data) else { return [] }

        var commands: [Self] = []
        for (id, installs) in manifest.plugins.sorted(by: { $0.key < $1.key }) {
            guard let name = id.split(separator: "@").first else { continue }

            let applicable = installs.filter { install in
                guard let project = install.projectPath else { return true }
                guard let folder else { return false }

                let root = URL(filePath: project, directoryHint: .isDirectory).standardizedFileURL.path
                return folder.path == root || folder.path.hasPrefix(root + "/")
            }
            for install in applicable.sorted(by: { ($0.projectPath?.count ?? 0) > ($1.projectPath?.count ?? 0) }) where install.installPath.hasPrefix("/") {
                let path = URL(filePath: install.installPath, directoryHint: .isDirectory)
                commands += claudeCommands(in: path, source: String(name), namespace: String(name))
            }
        }
        return commands
    }

    private static func claudeCommands(in directory: URL, source: String, namespace: String? = nil) -> [Self] {
        let commands = markdown(in: directory.appending(path: "commands"), recursively: namespace == nil)
        let skills = (try? FileManager.default.contentsOfDirectory(at: directory.appending(path: "skills"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return commands.compactMap { read($0, source: source, namespace: namespace) } + skills.sorted(by: { $0.path < $1.path }).compactMap { skill in
            read(skill.appending(path: "SKILL.md"), source: source, namespace: namespace, skillName: skill.lastPathComponent)
        }
    }

    private static func markdown(in directory: URL, recursively: Bool = false) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = recursively ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: options) else { return [] }

        return files.compactMap { $0 as? URL }.filter { file in
            file.pathExtension == "md" && (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
        }
        .sorted { $0.path < $1.path }
    }

    private static func read(_ file: URL, source: String, namespace: String?, skillName: String? = nil) -> Self? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        let frontmatter = MarkdownFrontmatter.split(text)
        var metadata: [String: String] = [:]
        if case let .entries(entries)? = frontmatter?.content {
            for entry in entries where !entry.value.isEmpty { metadata[entry.key] = entry.value }
        }
        if skillName != nil, metadata["user-invocable"]?.lowercased() == "false" { return nil }

        let name = if let skillName { metadata["name"] ?? skillName } else { file.deletingPathExtension().lastPathComponent }
        guard !name.isEmpty, !name.contains(where: \.isWhitespace), !name.contains("/") else { return nil }

        let description = metadata["description"]?.split(whereSeparator: \.isNewline).drop(while: { $0.wholeMatch(of: /[|>][-+]?/) != nil })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let bodyLine = (frontmatter?.body ?? text).split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let summary = description.flatMap { $0.isEmpty ? nil : $0 } ?? bodyLine
        let prefix = namespace.map { "\($0):" } ?? ""
        return Self("/\(prefix)\(name)", summary.count > 120 ? String(summary.prefix(119)) + "…" : summary, source: source, argumentHint: metadata["argument-hint"])
    }
}
#endif
