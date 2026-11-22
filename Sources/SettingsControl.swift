import BerthCore
import SwiftUI

@Observable
final class ControlInstaller {
    static let cliLink = URL.homeDirectory.appending(path: ".local/bin/berth")
    static let skillFile = Store.claudeDirectory.appending(path: "skills/berth/SKILL.md")
    static let settingsFile = Store.claudeDirectory.appending(path: "settings.json")

    private(set) var isCLIInstalled = FileManager.default.destinationOfSymbolicLinkOrNil(ControlInstaller.cliLink) == ControlService.cliTool?.path
    private(set) var isSkillInstalled = FileManager.default.fileExists(atPath: ControlInstaller.skillFile.path) && ControlInstall.hasHook(in: try? Data(contentsOf: ControlInstaller.settingsFile))
    var failure: String?

    func installCLI() {
        guard let tool = ControlService.cliTool, FileManager.default.isExecutableFile(atPath: tool.path) else { return failure = "This build of Berth has no berth-cli tool" }

        let link = Self.cliLink
        do {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.destinationOfSymbolicLinkOrNil(link) != nil { try FileManager.default.removeItem(at: link) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
            isCLIInstalled = true
            failure = nil
        } catch {
            failure = "Couldn’t link \(link.path): \(error.localizedDescription)"
        }
    }

    func installSkill() {
        do {
            let existing = try? Data(contentsOf: Self.settingsFile)
            let merged = try ControlInstall.settings(adding: existing)
            try FileManager.default.createDirectory(at: Self.skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ControlInstall.skill.utf8).write(to: Self.skillFile, options: .atomic)
            if let existing, merged != existing {
                let backup = Self.settingsFile.appendingPathExtension("berth-backup")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.copyItem(at: Self.settingsFile, to: backup)
            }
            if merged != existing { try merged.write(to: Self.settingsFile, options: .atomic) }
            isSkillInstalled = true
            failure = nil
        } catch let error as ControlInstall.SettingsError {
            failure = error.message
        } catch {
            failure = error.localizedDescription
        }
    }
}

private extension FileManager {
    func destinationOfSymbolicLinkOrNil(_ url: URL) -> String? {
        try? destinationOfSymbolicLink(atPath: url.path)
    }
}

struct ControlInstallRows: View {
    let installer: ControlInstaller
    @State private var showsSkillSheet = false

    var body: some View {
        LabeledContent("berth command") {
            Button(installer.isCLIInstalled ? "Reinstall" : "Install") { installer.installCLI() }
        }
        LabeledContent("Claude Code skill and hook") {
            Button(installer.isSkillInstalled ? "Reinstall…" : "Install…") { showsSkillSheet = true }
        }
        if let failure = installer.failure {
            Text(failure).foregroundStyle(.red)
        }
        Text(installer.isCLIInstalled ? "Linked at ~/.local/bin/berth." : "Links ~/.local/bin/berth to the tool inside Berth. Add that folder to your PATH if it isn’t there.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .sheet(isPresented: $showsSkillSheet) { ControlSkillSheet(installer: installer) }
    }
}

private struct ControlSkillSheet: View {
    let installer: ControlInstaller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install the Claude Code skill and hook")
                .font(.headline)
            Text("Nothing is written until you click Install. Berth will:")
            VStack(alignment: .leading, spacing: 4) {
                Text("Write the skill to \(ControlInstaller.skillFile.path(percentEncoded: false)).")
                Text("Add this SessionStart hook to \(ControlInstaller.settingsFile.path(percentEncoded: false)), keeping the rest of the file and a backup beside it:")
            }
            ScrollView {
                Text(ControlInstall.hookPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            if let failure = installer.failure {
                Text(failure).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Install") {
                    installer.installSkill()
                    if installer.failure == nil { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
