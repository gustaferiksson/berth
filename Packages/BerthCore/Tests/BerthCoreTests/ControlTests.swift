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

    @Test func theControlTokenSurvivesRelaunch() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let control = directory + "/control"
        let path = ControlEnvironment.socketPath(directory: control)
        let tokenPath = control + "/token"
        let token = try ControlEnvironment.persistentToken(directory: control)
        #expect(try FileManager.default.attributesOfItem(atPath: control)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: tokenPath)[.posixPermissions] as? Int == 0o600)

        let server = ControlServer(path: path, token: token) { _ in ControlResponse() }
        try server.start()
        server.stop()

        let savedToken = try ControlEnvironment.persistentToken(directory: control)
        let relaunched = ControlServer(path: path, token: savedToken) { _ in ControlResponse() }
        try relaunched.start()
        defer { relaunched.stop() }

        let response = try ControlClient.send(ControlRequest(token: token, caller: "caller-tab", operation: .list), socketPath: path)
        #expect(response.succeeded)
    }

    @Test func aMalformedControlTokenIsReplaced() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let file = URL(filePath: directory + "/token")
        try Data(String(repeating: "z", count: 64).utf8).write(to: file)

        let token = try ControlEnvironment.persistentToken(directory: directory)
        #expect(token.wholeMatch(of: /[0-9a-f]{64}/) != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == token)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
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
        #expect(response.error == "Wrong token: this tab holds an out-of-date Berth token (control was switched off and on, or the tab predates saved tokens). Open a new tab to use berth here.")
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

        let session = try parse(["open-session", "--cwd", "../api", "--background", "--json", "--", "review", "the PR"])
        #expect(session.request == ControlRequest(token: "tok", caller: "me", operation: .openSession, cwd: "/work/api", text: "review the PR", background: true))
        #expect(session.json)

        let quoted = try parse(["open-session", "--", #"check "quoted text""#, "it's ready", "--json"])
        #expect(quoted.request.text == #"check "quoted text" it's ready --json"#)
        #expect(!quoted.json)
        #expect(try parse(["open-session"]).request == ControlRequest(token: "tok", caller: "me", operation: .openSession))
        #expect(try parse(["open-session", "--"]).request.text == nil)
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open-session", "--unknown"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open-session", "--cwd"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open-session", "--cwd", "--background"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open-session", "hello"]) }

        let show = try parse(["open", "../notes/plan folder", "--background", "--json"])
        #expect(show.request == ControlRequest(token: "tok", caller: "me", operation: .openPath, path: "/work/notes/plan folder", background: true))
        #expect(show.json)
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open", "a", "b"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open", "--cwd", "/x", "a"]) }

        #expect(try parse(["open-url", "http://localhost:3000/invoices", "--background"]).request == ControlRequest(token: "tok", caller: "me", operation: .openURL, background: true, url: "http://localhost:3000/invoices"))
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open-url", "file:///etc/passwd"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open-url", "javascript:alert(1)"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["open-url"]) }

        let send = try parse(["send", "ab12", "hello", "world", "--no-enter"]).request
        #expect(send.tab == "ab12" && send.text == "hello world" && send.enter == false)
        #expect(try parse(["wait", "ab12", "--timeout", "30"]).request.timeout == 30)

        #expect(throws: ControlCommand.UsageError.self) { try parse(["close"]) }
        #expect(throws: ControlCommand.UsageError.self) { try parse(["bogus"]) }
        #expect(throws: ControlCommand.UsageError.self) { try ControlCommand.parse(["ls"], environment: [:], currentDirectory: "/") }
    }

    @Test func openSessionRequestRoundTripsThroughJSON() throws {
        let request = ControlRequest(token: "tok", caller: "me", operation: .openSession, cwd: "/work/api", text: "review the PR", background: true)
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["operation"] as? String == "open-session")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)
    }

    @Test func showPullRequestParsesNumbersURLsAndClonePaths() throws {
        let environment = [ControlEnvironment.socket: "/s.sock", ControlEnvironment.token: "tok", ControlEnvironment.tab: "me"]
        let number = try ControlCommand.parse(["show-pr", "42"], environment: environment, currentDirectory: "/work/app")
        #expect(number.request == ControlRequest(token: "tok", caller: "me", operation: .showPullRequest, pullRequest: 42))

        let url = try ControlCommand.parse(["show-pr", "https://github.com/Acme/api.v2/pull/42?tab=files#changes", "--repo", "../api", "--json"], environment: environment, currentDirectory: "/work/app")
        #expect(url.request == ControlRequest(token: "tok", caller: "me", operation: .showPullRequest, pullRequest: 42, repository: "Acme/api.v2", repositoryPath: "/work/api"))
        #expect(url.json)

        for arguments in [
            ["0"], ["-1"], ["999999999999999999999999999"], ["42", "43"], ["42", "--repo"], ["42", "--repo", "--json"],
            ["https://github.com/acme/api/pull/0"], ["http://github.com/acme/api/pull/42"], ["https://example.com/acme/api/pull/42"],
            ["https://github.com/-acme/api/pull/42"], ["https://github.com/acme/../pull/42"], ["https://github.com/acme/a%2Fb/pull/42"],
            ["https://github.com/acme/api/issues/42"],
        ] {
            #expect(throws: ControlCommand.UsageError.self) { try ControlCommand.parse(["show-pr"] + arguments, environment: environment, currentDirectory: "/work/app") }
        }
    }

    @Test func showPullRequestRequestRoundTripsThroughJSON() throws {
        let request = ControlRequest(token: "tok", caller: "me", operation: .showPullRequest, pullRequest: 42, repository: "acme/api", repositoryPath: "/work/api")
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["operation"] as? String == "show-pr")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: data) == request)

        let legacy = Data(#"{"token":"tok","caller":"me","operation":"ls"}"#.utf8)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: legacy) == ControlRequest(token: "tok", caller: "me", operation: .list))
    }

    @Test func usageAndSkillDescribeOpeningSessions() {
        #expect(ControlCommand.usage.contains("berth open-session [--cwd <dir>] [--background] [--json] [-- <prompt words>]"))
        let showSyntax = "berth show-pr <number|url> [--repo <path>] [--json]"
        #expect(ControlCommand.usage.contains(showSyntax))
        #expect(ControlInstall.skill.contains(showSyntax))
        #expect(ControlInstall.skill.contains("If the user asks for a separate working session"))
        #expect(ControlInstall.hookCommand.contains("berth show-pr"))
        #expect(ControlInstall.skill.contains(#"berth open-session --cwd <worktree> --background -- "<prompt>""#))
    }

    @Test func openPathRequestReachesTheHandler() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = ControlEnvironment.socketPath(directory: directory)
        let server = ControlServer(path: path, token: "secret") { request in
            ControlResponse(tab: request.operation == .openPath ? "abcd1234" : nil, text: request.path)
        }
        try server.start()
        defer { server.stop() }

        let response = try ControlClient.send(ControlRequest(token: "secret", caller: "me", operation: .openPath, path: "/work/app"), socketPath: path)

        #expect(response == ControlResponse(tab: "abcd1234", text: "/work/app"))
        #expect(ControlCommand.usage.contains("berth open <path> [--background] [--json]"))
        #expect(ControlInstall.skill.contains("berth open <path>"))
    }

    @Test func refreshUpdatesAnInstalledSkillAndHookButInstallsNothing() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let skillFile = URL(filePath: directory + "/skills/berth/SKILL.md")
        let settingsFile = URL(filePath: directory + "/settings.json")

        try ControlInstall.refreshInstalled(skillFile: skillFile, settingsFile: settingsFile)
        #expect(!FileManager.default.fileExists(atPath: skillFile.path))
        #expect(!FileManager.default.fileExists(atPath: settingsFile.path))

        let oldHook = #"[ -z "$BERTH_TAB_ID" ] || printf 'old hint'"#
        let hooks: [[String: String]] = [["type": "command", "command": "echo hi"], ["type": "command", "command": oldHook]]
        let settings = try JSONSerialization.data(withJSONObject: ["model": "opus", "hooks": ["SessionStart": [["hooks": hooks]]]], options: .sortedKeys)
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: berth\n---\nuses BERTH_TAB_ID, old text".utf8).write(to: skillFile)
        try settings.write(to: settingsFile)

        try ControlInstall.refreshInstalled(skillFile: skillFile, settingsFile: settingsFile)

        #expect(try String(contentsOf: skillFile, encoding: .utf8) == ControlInstall.skill)
        let refreshed = try Data(contentsOf: settingsFile)
        #expect(ControlInstall.hasHook(in: refreshed))
        #expect(String(decoding: refreshed, as: UTF8.self).contains("echo hi"))
        #expect(try Data(contentsOf: settingsFile.appendingPathExtension("berth-backup")) == settings)

        try ControlInstall.refreshInstalled(skillFile: skillFile, settingsFile: settingsFile)
        #expect(try Data(contentsOf: settingsFile) == refreshed)
    }

    @Test func refreshLeavesFilesBerthDidNotInstall() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let skillFile = URL(filePath: directory + "/SKILL.md")
        let settingsFile = URL(filePath: directory + "/settings.json")
        try Data("---\nname: mine\n---\nmy own skill".utf8).write(to: skillFile)
        try Data(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#.utf8).write(to: settingsFile)

        try ControlInstall.refreshInstalled(skillFile: skillFile, settingsFile: settingsFile)

        #expect(try String(contentsOf: skillFile, encoding: .utf8) == "---\nname: mine\n---\nmy own skill")
        #expect(!FileManager.default.fileExists(atPath: settingsFile.appendingPathExtension("berth-backup").path))
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
