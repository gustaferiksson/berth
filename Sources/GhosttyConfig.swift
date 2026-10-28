import Foundation
import GhosttyTerminal

enum GhosttyConfig {
    static let controller: TerminalController = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userConfig = [
            "\(home)/.config/ghostty/config",
            "\(home)/.config/ghostty/config.ghostty",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ]
        .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        .joined(separator: "\n")
        let lines = userConfig.split(separator: "\n", omittingEmptySubsequences: false)
        let themeName = lines.compactMap { line -> String? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "theme" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.last
        let themeContents = themeName.flatMap { name in
            ["\(home)/.config/ghostty/themes/\(name)", "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)"]
                .lazy
                .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
                .first
        } ?? ""
        let withoutTheme = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("theme") }
        let contents = ([themeContents] + withoutTheme.map(String.init)).joined(separator: "\n")
        let controller = TerminalController(configSource: .generated(contents), theme: TerminalTheme())
        if let issue = controller.lastConfigurationIssue {
            NSLog("Berth: Ghostty config issue: %@", issue)
        }
        return controller
    }()
}
