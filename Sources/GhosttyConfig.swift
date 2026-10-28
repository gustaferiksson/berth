import Foundation
import GhosttyTerminal
import SwiftUI

enum GhosttyConfig {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let directories = ["\(home)/.config/ghostty", "\(home)/Library/Application Support/com.mitchellh.ghostty"]
    static let configFiles = directories.flatMap { ["\($0)/config", "\($0)/config.ghostty"] }.filter { FileManager.default.fileExists(atPath: $0) }
    // App shortcuts the embedded surface would otherwise swallow (Settings, new, search, quit, close window, fullscreen, tab switching).
    static let appKeybinds = (
        ["super+comma", "super+shift+comma", "super+n", "super+t", "super+q", "super+shift+f", "super+shift+w", "super+alt+w", "super+enter"]
            + ["super+9", "super+shift+[", "super+shift+]", "ctrl+tab", "ctrl+shift+tab"]
            + (1...8).flatMap { ["super+\($0)", "super+digit_\($0)"] }
    ).map { "keybind = \($0)=unbind" }

    static let controller: TerminalController = {
        let controller = TerminalController(configSource: .generated(load().contents), theme: TerminalTheme())
        if let issue = controller.lastConfigurationIssue {
            NSLog("Berth: Ghostty config issue: %@", issue)
        }
        return controller
    }()

    static func load() -> (contents: String, values: [String: String]) {
        #if DEBUG
        let override = UserDefaults.standard.string(forKey: "snapshotGhosttyTheme").map { "theme = \($0)" }
        #else
        let override: String? = nil
        #endif
        let userConfig = override ?? configFiles
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let lines = userConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let themeContents = settings(in: lines).last { $0.key == "theme" }.flatMap { themeFile(named: $0.value) } ?? ""
        let withoutTheme = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("theme") }
        let combined = [themeContents] + withoutTheme
        let values = settings(in: combined.flatMap { $0.split(separator: "\n").map(String.init) }).reduce(into: [String: String]()) { values, setting in
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
        let lines = configFiles
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
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
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
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
    let foreground: Color
    let secondary: Color
    let needsYou: Color
    let working: Color
    let branch: Color
    let merged: Color
    let closed: Color

    init(values: [String: String]) {
        let background = values["background"].flatMap(RGB.init(hex:))
        let surface = background ?? RGB(red: 1, green: 1, blue: 1)
        let readable = { (key: String, fallback: Color) -> Color in
            guard let rgb = values[key].flatMap(RGB.init(hex:)), rgb.contrast(with: surface) >= 4.5 else { return fallback }
            return rgb.color
        }
        isDark = surface.luminance < 0.18
        self.background = background?.color
        foreground = readable("foreground", .primary)
        secondary = foreground.opacity(0.6)
        needsYou = readable("palette-3", .orange)
        working = readable("palette-2", .green)
        branch = readable("palette-6", .teal)
        merged = readable("palette-5", .purple)
        closed = readable("palette-1", .red)
    }
}

private struct RGB {
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

    func contrast(with other: RGB) -> Double {
        let (light, dark) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (light + 0.05) / (dark + 0.05)
    }
}

extension EnvironmentValues {
    @Entry var ghosttyTheme = GhosttyTheme(values: [:])
}
