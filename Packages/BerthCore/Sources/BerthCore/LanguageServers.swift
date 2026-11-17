import Foundation

public struct LanguageServerCommand: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum LanguageServers {
    private static let languageIDs = [
        "swift": "swift", "rs": "rust",
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "typescriptreact",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascriptreact",
    ]
    private static let typeScriptLanguageIDs: Set = ["typescript", "typescriptreact", "javascript", "javascriptreact"]

    public static func languageID(forFile path: String) -> String? {
        languageIDs[URL(filePath: path).pathExtension.lowercased()]
    }

    public static func command(forLanguage languageID: String, root: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> LanguageServerCommand? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)

        if languageID == "swift" {
            return firstExecutable(path.map { "\($0)/sourcekit-lsp" } + ["/usr/bin/sourcekit-lsp"]).map { LanguageServerCommand(executable: $0, arguments: []) }
        }

        if languageID == "rust" {
            let candidates = (path + ["\(home)/.cargo/bin"]).map { "\($0)/rust-analyzer" }
                + ["\(home)/.rustup/toolchains/*/bin/rust-analyzer", "\(home)/.vscode/extensions/*/server/rust-analyzer"]
            return firstExecutable(candidates).map { LanguageServerCommand(executable: $0, arguments: []) }
        }

        let zed = "\(home)/Library/Application Support/Zed"
        guard typeScriptLanguageIDs.contains(languageID),
              let script = firstExecutable(["\(root)/node_modules/.bin/typescript-language-server"] + path.map { "\($0)/typescript-language-server" }
                  + ["\(zed)/languages/typescript-language-server/node_modules/.bin/typescript-language-server"]),
              let node = firstExecutable(path.map { "\($0)/node" }
                  + ["\(home)/.nvm/versions/node/*/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node", "\(zed)/node/*/bin/node"])
        else { return nil }
        return LanguageServerCommand(executable: node, arguments: [script, "--stdio"])
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
