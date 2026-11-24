import AppKit

enum SyntaxColorSource: String, CaseIterable {
    case terminal, vscode

    var title: String { self == .vscode ? "VS Code theme" : "Terminal theme" }
}

final class VSCodeTheme: Equatable {
    private struct Rule {
        let scope: String
        let foreground: NSColor?
        let italic: Bool?
    }

    private struct Source {
        let colors: [String: String]
        let rules: [Rule]
        let type: String?
    }

    static let active = load()

    private static let shorthands = [
        "comments": ["comment"], "strings": ["string"], "keywords": ["keyword"], "numbers": ["constant.numeric"],
        "types": ["entity.name.type", "support.type"], "functions": ["entity.name.function", "support.function"], "variables": ["variable", "support.variable"],
    ]

    private static let scopes = [
        "comment": "comment.line", "comment.documentation": "comment.block.documentation",
        "string": "string.quoted", "string.escape": "constant.character.escape", "escape": "constant.character.escape", "string.regexp": "string.regexp",
        "string.special.key": "support.type.property-name", "string.special": "string.other", "character": "string.quoted.single", "character.special": "constant.character",
        "number": "constant.numeric", "number.float": "constant.numeric.decimal", "boolean": "constant.language.boolean",
        "constant": "variable.other.constant", "constant.builtin": "constant.language", "constant.macro": "constant.language",
        "keyword": "keyword", "keyword.conditional": "keyword.control", "keyword.repeat": "keyword.control", "keyword.return": "keyword.control", "keyword.exception": "keyword.control",
        "keyword.import": "keyword.control", "keyword.coroutine": "keyword.control", "keyword.directive": "keyword.control.directive", "keyword.operator": "keyword.operator",
        "keyword.function": "storage.type.function", "keyword.type": "storage.type", "keyword.modifier": "storage.modifier",
        "operator": "keyword.operator",
        "function": "entity.name.function", "function.builtin": "support.function", "function.macro": "entity.name.function.macro",
        "constructor": "entity.name.type", "type": "entity.name.type", "type.builtin": "support.type.primitive",
        "property": "variable.other.property", "variable.member": "variable.other.property", "attribute": "entity.other.attribute-name",
        "variable": "variable", "variable.parameter": "variable.parameter", "variable.builtin": "variable.language",
        "tag": "entity.name.tag", "tag.attribute": "entity.other.attribute-name",
        "punctuation.delimiter": "punctuation.separator", "punctuation.special": "punctuation.definition", "punctuation.bracket": "punctuation.definition.block",
        "namespace": "entity.name.namespace", "label": "entity.name.label",
        "text.title": "markup.heading", "text.emphasis": "markup.italic", "text.strong": "markup.bold", "text.literal": "markup.inline.raw", "text.uri": "markup.underline.link", "text.reference": "string.other.link",
        "import": "keyword.control", "charset": "keyword.control", "keyframes": "keyword.control", "media": "keyword.control", "supports": "keyword.control",
    ]

    let isDark: Bool
    private let rules: [Rule]
    private let foreground: NSColor
    private let brackets: [NSColor]
    private var resolved: [String: (color: NSColor, italic: Bool)] = [:]

    private init(isDark: Bool, rules: [Rule], foreground: NSColor, brackets: [NSColor]) {
        self.isDark = isDark
        self.rules = rules
        self.foreground = foreground
        self.brackets = brackets
    }

    static func == (lhs: VSCodeTheme, rhs: VSCodeTheme) -> Bool { lhs === rhs }

    func color(forCapture capture: String) -> NSColor {
        if capture.hasPrefix("punctuation.bracket."), let depth = Int(capture.suffix(1)) { return brackets[depth] }

        return resolve(capture).color
    }

    func isItalic(forCapture capture: String) -> Bool {
        resolve(capture).italic
    }

    private func resolve(_ capture: String) -> (color: NSColor, italic: Bool) {
        if let cached = resolved[capture] { return cached }

        let target = Self.scope(for: capture)
        let matching = rules.enumerated()
            .filter { $0.element.scope.isEmpty || target == $0.element.scope || target.hasPrefix($0.element.scope + ".") }
            .sorted { ($0.element.scope.count, $0.offset) < ($1.element.scope.count, $1.offset) }
        var result = (color: foreground, italic: false)
        for (_, rule) in matching {
            result = (rule.foreground ?? result.color, rule.italic ?? result.italic)
        }
        resolved[capture] = result

        return result
    }

    private static func scope(for capture: String) -> String {
        if let scope = scopes[capture] { return scope }
        guard let dot = capture.lastIndex(of: ".") else { return "" }

        return scope(for: String(capture[..<dot]))
    }

    private static func load() -> VSCodeTheme? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let settings = json(home.appending(path: "Library/Application Support/Code/User/settings.json")),
              let name = settings["workbench.colorTheme"] as? String,
              let file = themeFile(named: name, home: home),
              let source = read(file)
        else { return nil }

        let customizations = settings["editor.tokenColorCustomizations"] as? [String: Any] ?? [:]
        let layers = [customizations, customizations["[\(name)]"] as? [String: Any] ?? [:]]
        let custom = layers.flatMap { layer in
            rules(from: layer["textMateRules"] as? [[String: Any]] ?? []) + shorthands.flatMap { key, scopes -> [Rule] in
                guard let value = layer[key] else { return [] }

                return rules(from: [["scope": scopes, "settings": value as? [String: Any] ?? ["foreground": value]]])
            }
        }
        let isDark = source.type.map { ["dark", "hcDark"].contains($0) } ?? true
        let brackets = [("editorBracketHighlight.foreground1", "#FFD700"), ("editorBracketHighlight.foreground2", "#DA70D6"), ("editorBracketHighlight.foreground3", "#179FFF")]
            .compactMap { key, fallback in color(source.colors[key] ?? fallback) }
        let foreground = source.colors["editor.foreground"].flatMap(color) ?? (isDark ? .white : .black)
        guard brackets.count == 3 else { return nil }

        return VSCodeTheme(isDark: isDark, rules: source.rules + custom, foreground: foreground, brackets: brackets)
    }

    private static func themeFile(named name: String, home: URL) -> URL? {
        let roots = [URL(filePath: "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions"), home.appending(path: ".vscode/extensions")]
        let folders = roots.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        for folder in folders {
            let contributes = json(folder.appending(path: "package.json"))?["contributes"] as? [String: Any]
            let localized = json(folder.appending(path: "package.nls.json")) ?? [:]
            let match = (contributes?["themes"] as? [[String: Any]])?.first { theme in
                let label = (theme["label"] as? String).map { $0.hasPrefix("%") ? localized[String($0.dropFirst().dropLast())] as? String : $0 }
                return label == name || theme["id"] as? String == name
            }
            if let path = match?["path"] as? String { return folder.appending(path: path) }
        }

        return nil
    }

    private static func read(_ url: URL, depth: Int = 0) -> Source? {
        guard let theme = json(url) else { return nil }

        let included = (theme["include"] as? String).flatMap { depth < 4 ? read(url.deletingLastPathComponent().appending(path: $0), depth: depth + 1) : nil }

        return Source(
            colors: (included?.colors ?? [:]).merging(theme["colors"] as? [String: String] ?? [:]) { $1 },
            rules: (included?.rules ?? []) + rules(from: theme["tokenColors"] as? [[String: Any]] ?? []),
            type: theme["type"] as? String ?? included?.type
        )
    }

    private static func rules(from entries: [[String: Any]]) -> [Rule] {
        entries.flatMap { entry -> [Rule] in
            let settings = entry["settings"] as? [String: Any] ?? [:]
            let foreground = (settings["foreground"] as? String).flatMap(color)
            let italic = (settings["fontStyle"] as? String).map { $0.contains("italic") }
            let selectors = entry["scope"] as? [String] ?? (entry["scope"] as? String).map { [$0] } ?? [""]

            return selectors
                .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
                .filter { !$0.contains(" ") }
                .map { Rule(scope: $0, foreground: foreground, italic: italic) }
        }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: .json5Allowed) } as? [String: Any]
    }

    private static func color(_ hex: String) -> NSColor? {
        guard hex.hasPrefix("#") else { return nil }

        let raw = String(hex.dropFirst())
        let digits = raw.count == 3 || raw.count == 4 ? raw.map { "\($0)\($0)" }.joined() : raw
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }

        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        return NSColor(srgbRed: CGFloat(rgba >> 24) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255, blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
}
