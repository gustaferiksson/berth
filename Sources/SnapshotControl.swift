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

        store.control.update()
        let caller = UUID()
        store.openShell(cwd: NSHomeDirectory(), command: "exec cat", id: caller)
        let environment = store.control.environment(for: caller)
        print("tab environment keys \(store.control.environment(for: caller).keys.sorted()), failure \(store.control.failure ?? "none")")

        func berth(_ arguments: String..., environment: [String: String] = environment) async -> String {
            await Task.detached {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = tool
                process.arguments = arguments
                process.environment = environment
                process.standardOutput = pipe
                process.standardError = pipe
                try? process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return "[\(process.terminationStatus)] " + String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
        }

        await print("ls: \(berth("ls"))")
        let folder = FileManager.default.temporaryDirectory
        let missingFolder = folder.appending(path: UUID().uuidString)
        await print("open-session in temp folder \(berth("open-session", "--cwd", folder.path, "--background", "--", "hello"))")
        await print("open-session in missing folder \(berth("open-session", "--cwd", missingFolder.path, "--background", "--", "hello"))")
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

        guard let image = image(of: window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }

        try? png.write(to: output)
        store.isTerminating = true
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }
}
#endif
