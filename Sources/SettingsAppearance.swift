import AppKit
import SwiftUI

struct AppearanceSettings: View {
    var body: some View {
        let configFile = GhosttyConfig.configFiles.last
        Form {
            Section {
                LabeledContent("Config", value: configFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                LabeledContent("Theme", value: GhosttyConfig.themeName ?? "Default")
                if let configFile {
                    HStack {
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: configFile)])
                        }
                    }
                }
            } header: {
                Text("Ghostty")
            } footer: {
                Text("Berth takes its colours and terminal settings from your Ghostty config. Edits apply right away.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}
