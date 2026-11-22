import AppKit
import SwiftUI

struct TerminalSettings: View {
    var body: some View {
        let configFile = GhosttyConfig.configFiles.last
        Form {
            Section {
                LabeledContent {
                    if let configFile {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: configFile)])
                        }
                    }
                } label: {
                    Text("Ghostty Config")
                    Text(configFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                }
                LabeledContent("Theme", value: GhosttyConfig.themeName ?? "Default")
            } header: {
                Text("Ghostty")
            } footer: {
                Text("Berth takes its colours and terminal settings from your Ghostty config. Edits apply right away.")
            }
            Section {
                LabeledContent {
                    Button("Edit…", action: GhosttyConfig.editOverrides)
                    Button("Reveal in Finder", action: GhosttyConfig.revealOverrides)
                } label: {
                    Text("Terminal Overrides")
                    Text("Ghostty settings that apply only inside Berth")
                }
                if let issue = GhosttyConfig.overrideIssue {
                    Text(issue)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Overrides")
            } footer: {
                Text("~/.config/berth/ghostty is read after your Ghostty config, so its settings win. Set the font, font size or theme there.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}
