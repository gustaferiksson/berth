import CoreText
import Foundation
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

enum GhosttyConfig {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let directories = ["\(home)/.config/ghostty", "\(home)/Library/Application Support/com.mitchellh.ghostty"]
    static let configFiles = directories.flatMap { ["\($0)/config", "\($0)/config.ghostty"] }.filter { FileManager.default.fileExists(atPath: $0) }
    // App shortcuts the embedded surface would otherwise swallow (Settings, new, palette, find, search, quit, close window, fullscreen, tab switching).
    static let appKeybinds = (
        ["super+comma", "super+shift+comma", "super+n", "super+t", "super+k", "super+q", "super+f", "super+shift+f", "super+shift+d", "super+shift+a", "super+shift+w", "super+alt+w", "super+enter"]
            + ["super+9", "super+shift+[", "super+shift+]", "ctrl+tab", "ctrl+shift+tab"]
            + (1...8).flatMap { ["super+\($0)", "super+digit_\($0)"] }
    ).map { "keybind = \($0)=unbind" }

    static func registerBundledFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    static var prefersDark: Bool {
        switch AppearanceMode.stored {
        case .dark: true
        case .light: false
        case .system: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
    }

    static let watchedPaths = directories + ["\(home)/.config"]
    static let overrideFile = "\(home)/.config/berth/ghostty"
    static let overrideExample = """
    # Ghostty settings that apply only inside Berth, read after your Ghostty config.
    # font-size = 14
    # theme = Atom One Dark
    # cursor-style = bar

    """

    private(set) static var overrideIssue: String?

    static let controller: TerminalController = {
        let controller = TerminalController(configSource: .generated(load().contents), theme: TerminalTheme())
        if let issue = controller.lastConfigurationIssue {
            NSLog("Berth: Ghostty config issue: %@", issue)
        }
        overrideIssue = dropRejectedOverrides(from: controller)
        return controller
    }()

    static var overrideText: String { (try? String(contentsOfFile: overrideFile, encoding: .utf8)) ?? "" }

    static var appliedValues: [String: String] {
        _ = controller
        return load(overrides: overrideIssue == nil ? overrideText : "").values
    }

    static func reload() {
        controller.updateConfigSource(.generated(load().contents))
        overrideIssue = dropRejectedOverrides(from: controller)
    }

    static func editOverrides() {
        if !FileManager.default.fileExists(atPath: overrideFile) {
            try? FileManager.default.createDirectory(atPath: (overrideFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? overrideExample.write(toFile: overrideFile, atomically: true, encoding: .utf8)
        }
        #if DEBUG
        if SettingsSnapshot.output != nil {
            print("snapshot edit \(overrideFile)")
            return
        }
        #endif
        let url = URL(filePath: overrideFile)
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    static func revealOverrides() {
        let url = URL(filePath: overrideFile)
        guard FileManager.default.fileExists(atPath: overrideFile) else {
            NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // libghostty rejects the whole config on any diagnostic, so a bad override line must not cost the user's own config.
    private static func dropRejectedOverrides(from controller: TerminalController) -> String? {
        guard let issue = controller.lastConfigurationIssue, !overrideText.isEmpty else { return nil }

        controller.updateConfigSource(.generated(load(overrides: "").contents))
        return controller.lastConfigurationIssue == nil ? issue.replacing(/\S+\.conf:/, with: "line ") : nil
    }

    static func load(overrides: String = overrideText) -> (contents: String, values: [String: String]) {
        #if DEBUG
        let themeOverride = UserDefaults.standard.string(forKey: "snapshotGhosttyTheme").map { "theme = \($0)" }
        #else
        let themeOverride: String? = nil
        #endif
        let userConfig = themeOverride ?? configFiles
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let lines = (userConfig + "\n" + overrides).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let themeContents = settings(in: lines).last { $0.key == "theme" }.flatMap { themeFile(named: $0.value) } ?? ""
        let withoutTheme = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("theme") }
        let combined = [themeContents] + withoutTheme
        let values = settings(in: combined.flatMap { $0.split(separator: "\n").map(String.init) }).reduce(into: [String: String]()) { values, setting in
            if setting.key == "font-feature" {
                values[setting.key] = [values[setting.key], setting.value].compactMap(\.self).joined(separator: ",")
                return
            }

            guard setting.key == "palette" else {
                values[setting.key] = setting.value
                return
            }

            let entry = setting.value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if entry.count == 2 { values["palette-\(entry[0])"] = entry[1] }
        }
        return ((combined + appKeybinds).joined(separator: "\n"), values)
    }

    static var themeName: String? {
        let lines = (configFiles.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) } + [overrideIssue == nil ? overrideText : ""])
            .flatMap { $0.split(separator: "\n").map(String.init) }
        return settings(in: lines).last { $0.key == "theme" }?.value
    }

    static func colorConfiguration(_ values: [String: String]) -> TerminalConfiguration {
        let keys = ["background", "foreground", "selection-background", "selection-foreground", "cursor-color", "cursor-text"]
        let palette = (0..<16).compactMap { index in values["palette-\(index)"].map { TerminalConfigCommand.palette(index: index, color: $0) } }
        let colors = keys.compactMap { key in values[key].map { TerminalConfigCommand.custom(key: key, value: $0) } }
        return (colors + palette).reduce(TerminalConfiguration()) { $0.appending($1) }
    }

    private static func settings(in lines: [String]) -> [(key: String, value: String)] {
        lines.compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }

            return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces))
        }
    }

    private static func themeFile(named value: String) -> String? {
        let isDark = prefersDark
        let variants = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let name = variants.first { $0.hasPrefix(isDark ? "dark:" : "light:") }.map { String($0.drop { $0 != ":" }.dropFirst()) } ?? value
        return ["\(home)/.config/ghostty/themes/\(name)", "/Applications/Ghostty.app/Contents/Resources/ghostty/themes/\(name)"]
            .lazy
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .first
    }
}

struct GhosttyTheme: Equatable {
    let isDark: Bool
    let background: Color?
    let chrome: Color?
    var foreground: Color
    let secondary: Color
    let needsYou: Color
    let warning: Color
    let working: Color
    let branch: Color
    let merged: Color
    let shellAttached: Color
    let closed: Color
    let unread: Color
    let inlineCode: Color
    let series: [Color]
    var font: NSFont
    var codeFont: NSFont
    var composerFont: NSFont
    var lineHeightMultiple: CGFloat = 1
    var codeStyle: ReviewStyle?
    var messageWidth: CGFloat = 860

    init(values: [String: String]) {
        let background = values["background"].flatMap(RGB.init(hex:))
        let surface = background ?? RGB(red: 1, green: 1, blue: 1)
        let readable = { (key: String, fallback: Color, minimum: Double) -> Color in
            guard let rgb = values[key].flatMap(RGB.init(hex:)), rgb.contrast(with: surface) >= minimum else { return fallback }

            return rgb.color
        }
        isDark = surface.luminance < 0.18
        self.background = background?.color
        chrome = background?.color.mix(with: .black, by: isDark ? 0.4 : 0.05).mix(with: .white, by: 0.03)
        foreground = readable("foreground", .primary, 4.5)
        secondary = foreground.opacity(0.6)
        needsYou = readable("palette-3", .orange, 4.5)
        warning = readable("palette-3", isDark ? Color(red: 229 / 255, green: 192 / 255, blue: 123 / 255) : Color(red: 150 / 255, green: 108 / 255, blue: 30 / 255), 4.5)
        working = readable("palette-2", .green, 4.5)
        branch = readable("palette-6", .teal, 4.5)
        merged = readable("palette-5", .purple, 4.5)
        shellAttached = values["palette-13"] == values["palette-5"] ? .pink : readable("palette-13", .pink, 4.5)
        closed = readable("palette-1", .red, 4.5)
        unread = readable("palette-4", .blue, 4.5)
        inlineCode = isDark ? Color(red: 177 / 255, green: 185 / 255, blue: 249 / 255) : Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
        let slots = [("palette-6", Color.teal), ("palette-1", .red), ("palette-4", .blue), ("palette-3", .yellow), ("palette-5", .purple), ("palette-2", .green)]
        series = slots.enumerated().map { index, slot in
            slots[(index + 1)...].contains { values[$0.0] == values[slot.0] } ? slot.1 : readable(slot.0, slot.1, 3)
        }
        let fontSize = values["font-size"].flatMap(Double.init) ?? 13
        let family = values["font-family"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? "JetBrains Mono"
        let base = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let features = (values["font-feature"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }.map { feature -> [String: Any] in
            let enabled = !feature.hasPrefix("-")
            let tag = String(feature.drop { $0 == "-" || $0 == "+" }.prefix(4))
            return [kCTFontOpenTypeFeatureTag as String: tag, kCTFontOpenTypeFeatureValue as String: enabled ? 1 : 0]
        }
        font = features.isEmpty ? base : NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: features]), size: fontSize) ?? base
        codeFont = font
        composerFont = .systemFont(ofSize: fontSize)
    }
}

struct RGB {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }

        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    var luminance: Double {
        let linear = [red, green, blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    func contrast(with other: Self) -> Double {
        let light = max(luminance, other.luminance)
        let dark = min(luminance, other.luminance)
        return (light + 0.05) / (dark + 0.05)
    }
}

extension EnvironmentValues {
    @Entry var ghosttyTheme = GhosttyTheme(values: [:])
}
