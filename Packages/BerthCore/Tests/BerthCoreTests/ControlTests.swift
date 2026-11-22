@testable import BerthCore
import Foundation
import Testing

struct ControlTests {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [ControlRequest] = []

        var all: [ControlRequest] { lock.withLock { requests } }

        func add(_ request: ControlRequest) {
            lock.withLock { requests.append(request) }
        }
    }

    @Test func requestsReachTheHandlerAndRepliesComeBack() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let seen = Seen()
        let path = ControlEnvironment.socketPath(directory: directory + "/control")
        let server = ControlServer(path: path, token: "secret") { request in
            seen.add(request)
            return ControlResponse(tab: "abcd1234", text: request.command, exit: 3)
        }
        try server.start()
        defer { server.stop() }

        let request = ControlRequest(token: "secret", caller: "caller-tab", operation: .open, cwd: "/tmp", command: "npm run dev", background: true)
        let response = try ControlClient.send(request, socketPath: path)

        #expect(response == ControlResponse(tab: "abcd1234", text: "npm run dev", exit: 3))
        #expect(seen.all == [request])
    }

    @Test func socketAndItsFolderAreOwnerOnly() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = ControlEnvironment.socketPath(directory: directory + "/control")
        let server = ControlServer(path: path, token: "secret") { _ in ControlResponse() }
        try server.start()
        defer { server.stop() }

        let socketMode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        let folderMode = try #require(FileManager.default.attributesOfItem(atPath: directory + "/control")[.posixPermissions] as? Int)
        #expect(socketMode == 0o600)
        #expect(folderMode == 0o700)
    }

    @Test func aWrongTokenNeverReachesTheHandler() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let seen = Seen()
        let path = ControlEnvironment.socketPath(directory: directory)
        let server = ControlServer(path: path, token: "secret") { request in
            seen.add(request)
            return ControlResponse()
        }
        try server.start()
        defer { server.stop() }

        let response = try ControlClient.send(ControlRequest(token: "guess", caller: "x", operation: .list), socketPath: path)

        #expect(!response.succeeded)
        #expect(seen.all.isEmpty)
    }

    @Test func tooLongSocketPathsAreRefused() {
        let path = ControlEnvironment.socketPath(directory: "/tmp/" + String(repeating: "x", count: 120))
        #expect(throws: ControlError.pathTooLong) { try ControlServer(path: path, token: "t") { _ in ControlResponse() }.start() }
    }

    @Test func cliBuildsRequestsFromArgumentsAndEnvironment() throws {
        let environment = ["BERTH_SOCKET": "/s.sock", "BERTH_TOKEN": "tok", "BERTH_TAB_ID": "me"]
        func parse(_ arguments: [String]) throws -> ControlCommand.Invocation {
            try ControlCommand.parse(arguments, environment: environment, currentDirectory: "/work/app")
        }

        let open = try parse(["open-terminal", "--cwd", "../api", "--background", "--", "npm", "run", "dev server"])
        #expect(open.request == ControlRequest(token: "tok", caller: "me", operation: .open, cwd: "/work/api", command: "'npm' 'run' 'dev server'", background: true))
        #expect(open.socketPath == "/s.sock")

        #expect(try parse(["open-terminal", "--", "npm run dev"]).request.command == "npm run dev")
        #expect(try parse(["open-terminal"]).request.command == nil)
        #expect(try parse(["ls", "--json"]).json)

        let send = try parse(["send", "ab12", "hello", "world", "--no-enter"]).request
        #expect(send.tab == "ab12" && send.text == "hello world" && send.enter == false)
        #expect(try parse(["wait", "ab12", "--timeout", "30"]).request.timeout == 30)

        #expect(throws: ControlCommand.UsageError.self) { try parse(["close"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["bogus"]) }
        #expect(throws: ControlCommand.UsageError.self) { try ControlCommand.parse(["ls"], environment: [:], currentDirectory: "/") }
    }

    @Test func exitStatusIsRecordedBeforeTheTabEnds() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let file = directory + "/it's here"
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", ControlExitStatus.wrapping("echo 'quoted' && exit 3", recordingIn: file)]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 3)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "3")
    }

    @Test func terminalOutputBecomesPlainText() {
        let raw = "\u{1B}[32mready\u{1B}[0m\r\n\u{1B}]0;title\u{07}progress 10%\rprogress 100%\r\ndone\r\n"
        #expect(TerminalText.plain(Array(raw.utf8)) == "ready\nprogress 100%\ndone\n")
    }

    @Test func installAddsTheHookOnceAndKeepsEverythingElse() throws {
        let existing = Data(#"{"model":"opus","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}],"Stop":[]}}"#.utf8)
        let merged = try ControlInstall.settings(adding: existing)
        let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let groups = try #require(hooks["SessionStart"] as? [[String: Any]])

        #expect(root["model"] as? String == "opus")
        #expect(hooks["Stop"] != nil)
        #expect(groups.count == 2)
        #expect(ControlInstall.hasHook(in: merged))
        #expect(try ControlInstall.settings(adding: merged) == merged)
        #expect(try ControlInstall.hasHook(in: ControlInstall.settings(adding: nil)))
    }

    @Test func installRefusesSettingsItCannotReadBack() {
        #expect(throws: ControlInstall.SettingsError.self) { try ControlInstall.settings(adding: Data("{ not json".utf8)) }
        #expect(throws: ControlInstall.SettingsError.self) { try ControlInstall.settings(adding: Data(#"{"hooks":[]}"#.utf8)) }
        #expect(throws: ControlInstall.SettingsError.self) { try ControlInstall.settings(adding: Data(#"{"hooks":{"SessionStart":{}}}"#.utf8)) }
    }

    private static func shortDirectory() throws -> String {
        let directory = "/tmp/bc-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }
}
