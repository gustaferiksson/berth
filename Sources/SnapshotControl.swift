#if DEBUG
import AppKit
import BerthCore
import Foundation

extension Snapshot {
    static func captureControl(store: Store, window: NSWindow, output: URL) async {
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil, let tool = ControlService.cliTool else {
            FileHandle.standardError.write(Data("snapshot: -snapshotControl needs CFFIXED_USER_HOME and the embedded berth-cli\n".utf8))
            exit(1)
        }

        let staleHook = #"[ -z "$BERTH_TAB_ID" ] || printf 'stale hint'"#
        let staleSettings = try? JSONSerialization.data(withJSONObject: ["hooks": ["SessionStart": [["hooks": [["type": "command", "command": staleHook]]]]]])
        try? FileManager.default.createDirectory(at: ControlInstaller.skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("---\nname: berth\n---\nBERTH_TAB_ID, stale".utf8).write(to: ControlInstaller.skillFile)
        try? staleSettings?.write(to: ControlInstaller.settingsFile)
        store.control.update()
        print("skill refreshed \((try? String(contentsOf: ControlInstaller.skillFile, encoding: .utf8)) == ControlInstall.skill), hook refreshed \(ControlInstall.hasHook(in: try? Data(contentsOf: ControlInstaller.settingsFile)))")
        let caller = UUID()
        store.openShell(cwd: NSHomeDirectory(), command: "exec cat", id: caller)
        let environment = store.control.environment(for: caller)
        print("tab environment keys \(store.control.environment(for: caller).keys.sorted()), failure \(store.control.failure ?? "none")")

        func berth(_ arguments: String..., environment: [String: String] = environment) async -> String {
            let result = await runControlCLI(tool, arguments: arguments, environment: environment)
            return "[\(result.status)] \(result.output)"
        }

        await print("ls: \(berth("ls"))")
        let folder = FileManager.default.temporaryDirectory
        let missingFolder = folder.appending(path: UUID().uuidString)
        await print("open-session in temp folder \(berth("open-session", "--cwd", folder.path, "--background", "--", "hello"))")
        await print("open-session in missing folder \(berth("open-session", "--cwd", missingFolder.path, "--background", "--", "hello"))")
        let scratch = folder.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let note = scratch.appending(path: "team-plan.md")
        try? Data("plan".utf8).write(to: note)
        await print("open folder \(berth("open", scratch.path, "--background"))")
        await print("open file \(berth("open", note.path))")
        await print("open missing path \(berth("open", missingFolder.path))")
        await print("open without path \(berth("open"))")
        print("probeOpened calls \(store.probeOpened.map { "\($0.agent.rawValue) \($0.cwd) \($0.start)" })")

        let finished = await berth("open-terminal", "--background", "--", "sh", "-c", "echo done-marker; exit 7")
        print("open finishing command: \(finished)")
        let finishedID = finished.split(separator: " ").last.map(String.init) ?? ""
        await print("wait: \(berth("wait", finishedID, "--timeout", "20"))")

        let opened = await berth("open-terminal", "--background", "--", "echo capture-marker; exec cat")
        let id = opened.split(separator: " ").last.map(String.init) ?? ""
        print("open long command: \(opened), selected tab unchanged \(store.selectedTabID == caller)")
        try? await Task.sleep(for: .seconds(2))
        await print("send: \(berth("send", id, "typed-text"))")
        try? await Task.sleep(for: .seconds(1))
        await print("capture: \(berth("capture", id))")
        await print("ls json: \(berth("ls", "--json"))")
        await print("send to own tab: \(berth("send", String(caller.uuidString.prefix(8)), "x"))")
        await print("close own tab: \(berth("close", String(caller.uuidString.prefix(8))))")
        await print("wait with timeout: \(berth("wait", id, "--timeout", "1"))")
        await print("close opened: \(berth("close", id)), tab still open \(store.tabs.contains { $0.id.uuidString.lowercased().hasPrefix(id) })")
        await print("wrong token: \(berth("ls", environment: environment.merging([ControlEnvironment.token: "guess"]) { _, new in new }))")
        await print("no environment: \(berth("ls", environment: [:]))")

        if let sessionClone = UserDefaults.standard.string(forKey: "snapshotControlSessionClone"),
           let pullRequestClone = UserDefaults.standard.string(forKey: "snapshotControlPullRequestClone") {
            let sessionTab = UUID()
            let sessionID = "snapshot-control-review"
            store.openShell(cwd: sessionClone, command: "exec cat", id: sessionTab)
            store.tabs = store.tabs.map { $0.id == sessionTab ? Tab(id: $0.id, kind: .claude, cwd: sessionClone, sessionID: sessionID, terminal: $0.terminal) : $0 }
            let owned = UUID()
            store.openShell(cwd: sessionClone, command: "exec cat", id: owned, parent: sessionTab)
            let ownedEnvironment = store.control.environment(for: owned)
            let before = store.tabs.count
            let api = await berth("show-pr", "1445", "--json", environment: ownedEnvironment)
            let missing = await berth("show-pr", "https://github.com/acme/billing-tools/pull/1445", environment: ownedEnvironment)
            let billing = await berth("show-pr", "https://github.com/acme/billing/pull/1445", "--repo", pullRequestClone, "--json", environment: ownedEnvironment)
            let repeated = await berth("show-pr", "https://github.com/Acme/Billing/pull/1445", environment: ownedEnvironment)
            let model = store.reviewModel
            let entries = store.sessionReviewPullRequests(of: sessionID, changes: model?.changes, excluding: nil)
            let repositories = entries.map(\.id.repository).sorted()
            let expanded = entries.allSatisfy { model?.expandedPullRequests.contains($0.id) == true && model?.pullRequestFiles[$0.location]?.files.isEmpty == false }
            let document = model?.selectedDocument
            print("show-pr number \(api)")
            print("show-pr no clone \(missing)")
            print("show-pr URL \(billing)")
            print("show-pr repeat \(repeated)")
            print("show-pr review repositories \(repositories), expanded \(expanded), selected \(document?.path ?? "-"), clone \(document?.root ?? "-")")
            guard api.hasPrefix("[0]"), billing.hasPrefix("[0]"), repeated.hasPrefix("[0]"),
                  missing.hasPrefix("[1]"), missing.contains("No local clone"), missing.contains("--repo <path>"),
                  store.showsReviewPanel, store.selectedTabID == sessionTab, store.tabs.count == before,
                  repositories == ["acme/api", "acme/billing"], expanded, model?.expansionOverrides["otherPullRequests"] == true,
                  let document, document.pullRequestLink?.repository == "acme/billing",
                  document.root == pullRequestClone, model?.isReadOnly(document) == true, model?.contents[document] != nil
            else {
                FileHandle.standardError.write(Data("show-pr control snapshot failed\n".utf8))
                exit(1)
            }
        }

        guard let image = image(of: window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }

        try? png.write(to: output)
        store.isTerminating = true
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }

    static func runControlCLI(_ tool: URL, arguments: [String], environment: [String: String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = tool
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return (1, error.localizedDescription)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}
#endif
