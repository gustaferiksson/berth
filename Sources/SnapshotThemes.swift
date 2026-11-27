#if DEBUG
import AppKit

enum SnapshotThemes {
    static let light = "Berth Snapshot Light"
    static let dark = "Berth Snapshot Dark"

    static let fixtures = [
        light: """
        background = #fafafa
        foreground = #383a42
        selection-background = #e5e5e6
        selection-foreground = #383a42
        cursor-color = #526eff
        palette = 0=#383a42
        palette = 1=#ca1243
        palette = 2=#50a14f
        palette = 3=#986801
        palette = 4=#4078f2
        palette = 5=#a626a4
        palette = 6=#0184bc
        palette = 7=#a0a1a7
        palette = 8=#696c77
        palette = 9=#ca1243
        palette = 10=#50a14f
        palette = 11=#c18401
        palette = 12=#4078f2
        palette = 13=#a626a4
        palette = 14=#0184bc
        palette = 15=#fafafa
        """,
        dark: """
        background = #282c34
        foreground = #abb2bf
        selection-background = #3e4451
        selection-foreground = #abb2bf
        cursor-color = #528bff
        palette = 0=#3f4451
        palette = 1=#e05561
        palette = 2=#8cc265
        palette = 3=#d18f52
        palette = 4=#4aa5f0
        palette = 5=#c162de
        palette = 6=#42b3c2
        palette = 7=#d7dae0
        palette = 8=#4f5666
        palette = 9=#ff616e
        palette = 10=#a5e075
        palette = 11=#f0a45d
        palette = 12=#4dc4ff
        palette = 13=#de73ff
        palette = 14=#4cd1e0
        palette = 15=#e6e6e6
        """,
    ]

    @MainActor
    static func applyAppearance() {
        guard let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") else { return }

        NSApp.appearance = NSAppearance(named: style == "Dark" ? .darkAqua : .aqua)
    }

    static var requested: String? {
        let defaults = UserDefaults.standard
        let choice = defaults.string(forKey: "snapshotTheme") ?? defaults.string(forKey: "AppleInterfaceStyle")
        guard let choice else { return nil }

        return choice.lowercased() == "dark" ? dark : light
    }
}
#endif
