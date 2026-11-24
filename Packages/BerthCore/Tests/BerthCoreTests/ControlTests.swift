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

    @Test func browserCommandsParseTheirOptions() throws {
        let environment = [ControlEnvironment.socket: "/s.sock", ControlEnvironment.token: "tok", ControlEnvironment.tab: "me"]
        func parse(_ arguments: [String]) throws -> ControlCommand.Invocation {
            try ControlCommand.parse(["browser"] + arguments, environment: environment, currentDirectory: "/work/app")
        }

        let tabs = try parse(["tabs", "--json"])
        #expect(tabs.request == ControlRequest(token: "tok", caller: "me", operation: .browserTabs))
        #expect(tabs.json)

        let screenshot = try parse(["screenshot", "--tab", "abcd", "--out", "../capture.png", "--full-page", "--json"])
        #expect(screenshot.request == ControlRequest(token: "tok", caller: "me", operation: .browserScreenshot, tab: "abcd", path: "/work/capture.png", fullPage: true))
        #expect(screenshot.json)

        let path = try #require(try parse(["screenshot"]).request.path)
        let file = URL(filePath: path)
        #expect(file.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.path)
        #expect(file.lastPathComponent.wholeMatch(of: /berth-screenshot-[0-9a-f]{8}\.png/) != nil)
        #expect(try parse(["screenshot"]).request.path != path)

        let console = try parse(["console", "--tab", "abcd", "--since", "41", "--follow", "--json"])
        #expect(console.request == ControlRequest(token: "tok", caller: "me", operation: .browserConsole, tab: "abcd", since: 41))
        #expect(console.follow && console.json)
        #expect(try !parse(["console"]).follow)

        for (name, operation) in [("url", ControlOp.browserURL), ("reload", .browserReload), ("text", .browserText), ("snapshot", .browserSnapshot)] {
            let invocation = try parse([name, "--tab", "abcd", "--json"])
            #expect(invocation.request == ControlRequest(token: "tok", caller: "me", operation: operation, tab: "abcd"))
            #expect(invocation.json)
        }

        let html = try parse(["html", "--tab", "abcd", "--selector", "#invoice input[name=email]", "--json"])
        #expect(html.request == ControlRequest(token: "tok", caller: "me", operation: .browserHTML, tab: "abcd", selector: "#invoice input[name=email]"))
        #expect(html.json)
        #expect(try parse(["html"]).request.selector == nil)

        let navigate = try parse(["navigate", "http://localhost:3000/preview", "--tab", "abcd", "--json"])
        #expect(navigate.request == ControlRequest(token: "tok", caller: "me", operation: .browserNavigate, tab: "abcd", url: "http://localhost:3000/preview"))
        #expect(navigate.json)
    }

    @Test func browserCommandsRejectInvalidArguments() {
        let environment = [ControlEnvironment.socket: "/s.sock", ControlEnvironment.token: "tok", ControlEnvironment.tab: "me"]
        for arguments in [
            [], ["bogus"], ["tabs", "--tab", "abcd"], ["tabs", "extra"],
            ["screenshot", "--out"], ["screenshot", "--out", "--full-page"], ["screenshot", "extra"],
            ["console", "--since"], ["console", "--since", "wat"], ["console", "--since", "-1"], ["console", "extra"],
            ["url", "--tab"], ["reload", "--follow"], ["text", "--full-page"],
            ["html", "--selector"], ["html", "--selector", "--json"], ["html", "--selector", ""], ["snapshot", "--selector", "main"], ["snapshot", "extra"],
            ["navigate"], ["navigate", "file:///tmp/page"], ["navigate", "javascript:alert(1)"], ["navigate", "https://example.invalid", "extra"],
        ] {
            #expect(throws: ControlCommand.UsageError.self) { try ControlCommand.parse(["browser"] + arguments, environment: environment, currentDirectory: "/") }
        }
    }

    @Test func browserInteractionsParseTheirOptions() throws {
        let environment = ControlEnvironment.variables(socketPath: "/tmp/control.sock", token: "tok", tab: "me")
        func parse(_ arguments: [String]) throws -> ControlCommand.Invocation {
            try ControlCommand.parse(["browser"] + arguments, environment: environment, currentDirectory: "/")
        }

        let blank = try parse(["open", "--background", "--json"])
        #expect(blank.request == ControlRequest(token: "tok", caller: "me", operation: .browserOpen, background: true))
        #expect(blank.json)
        let opened = try parse(["open", "http://localhost:3000"])
        #expect(opened.request == ControlRequest(token: "tok", caller: "me", operation: .browserOpen, url: "http://localhost:3000"))

        let actions: [([String], ControlOp, String?, String?)] = [
            (["click", "e12"], .browserClick, "e12", nil),
            (["fill", "#name", "Ada Lovelace"], .browserFill, "#name", "Ada Lovelace"),
            (["type", "Ada"], .browserType, nil, "Ada"),
            (["press", "Shift+Tab"], .browserPress, nil, "Shift+Tab"),
            (["select", "select", ""], .browserSelect, "select", ""),
            (["hover", "text=More info"], .browserHover, "text=More info", nil),
            (["scroll", "#footer"], .browserScroll, "#footer", nil),
            (["back"], .browserBack, nil, nil),
            (["forward"], .browserForward, nil, nil),
            (["eval", "return document.title"], .browserEval, nil, "return document.title"),
        ]
        for (arguments, operation, target, text) in actions {
            let invocation = try parse(arguments + ["--tab", "abcd", "--json"])
            #expect(invocation.request == ControlRequest(token: "tok", caller: "me", operation: operation, tab: "abcd", text: text, target: target))
            #expect(invocation.json)
        }

        #expect(try parse(["scroll", "--to", "bottom"]).request.scrollTo == "bottom")
        #expect(try parse(["scroll", "--by", "-125"]).request.scrollBy == -125)
        #expect(try parse(["fill", "--", "#name", "--literal"]).request.text == "--literal")
        #expect(try parse(["wait", "#ready"]).request.selector == "#ready")
        #expect(try parse(["wait", "--text", "Done"]).request.text == "Done")
        #expect(try parse(["wait", "--url", "/done"]).request.url == "/done")
        #expect(try parse(["wait", "--load"]).request.load == true)
        let wait = try parse(["wait", "--ms", "125", "--timeout", "0.5", "--tab", "abcd", "--json"])
        #expect(wait.request == ControlRequest(token: "tok", caller: "me", operation: .browserWait, tab: "abcd", timeout: 0.5, milliseconds: 125))
        #expect(wait.json)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(wait.request)) == wait.request)
    }

    @Test func browserInteractionsRejectInvalidArguments() {
        let environment = ControlEnvironment.variables(socketPath: "/tmp/control.sock", token: "tok", tab: "me")
        let bad = [
            ["open", "--tab", "abcd"], ["open", "file:///tmp/page"], ["open", "https://example.com", "https://example.org"],
            ["click"], ["fill", "e7"], ["type"], ["press"], ["select", "select"], ["hover"],
            ["scroll"], ["scroll", "#target", "--to", "top"], ["scroll", "--to", "bottom", "--by", "20"], ["scroll", "--to", "left"], ["scroll", "--by", "abc"],
            ["wait"], ["wait", "main", "--text", "Ready"], ["wait", "--url", "/home", "--load"], ["wait", "--load", "--load"],
            ["wait", "--ms"], ["wait", "--ms", "-1"], ["wait", "--ms", "0.1"],
            ["wait", "--load", "--timeout"], ["wait", "--load", "--timeout", "-1"], ["wait", "--load", "--timeout", "inf"],
            ["back", "extra"], ["forward", "extra"], ["eval"],
        ]
        for arguments in bad {
            #expect(throws: ControlCommand.UsageError.self) { try ControlCommand.parse(["browser"] + arguments, environment: environment, currentDirectory: "/") }
        }
    }

    @Test func browserRepliesRenderTabsConsoleAndPageText() {
        let outcome = #"{"action":"click","target":"button \"Save\"","url":"http://localhost:3000","title":"Preview","navigated":false}"#
        #expect(ControlCommand.render(ControlResponse(text: outcome), json: false) == outcome)
        let tabs = [
            ControlBrowserTab(id: "abcd1234", title: "Preview", url: "http://localhost:3000", loading: true, active: true),
            ControlBrowserTab(id: "abcd5678", title: "New Tab", url: nil, loading: false, active: false),
        ]
        #expect(ControlCommand.render(ControlResponse(browserTabs: tabs), json: false) == "* abcd1234  loading  Preview  http://localhost:3000\n  abcd5678  -  New Tab  -")

        let timestamp = Date(timeIntervalSinceReferenceDate: 42)
        let console = [
            ControlConsoleEntry(sequence: 2, level: "log", text: "Ready", timestamp: timestamp),
            ControlConsoleEntry(sequence: 3, level: "warn", text: "First\nSecond", timestamp: timestamp),
        ]
        #expect(ControlCommand.render(ControlResponse(console: console), json: false) == "2 log Ready\n3 warn First\\nSecond")
        #expect(ControlCommand.render(console[0], json: true) == #"{"level":"log","sequence":2,"text":"Ready","timestamp":42}"#)
        for output in ["<html>\n  <body></body>\n</html>", #"- heading "Ready" [level=1] [ref=e1]"#] {
            #expect(ControlCommand.render(ControlResponse(text: output), json: false) == output)
        }
    }

    @Test func browserHTMLRequestRoundTripsAndLegacyRequestsNeedNoSelector() throws {
        let oldRequest = Data(#"{"token":"tok","caller":"me","operation":"browser-text"}"#.utf8)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: oldRequest) == ControlRequest(token: "tok", caller: "me", operation: .browserText))

        let request = ControlRequest(token: "tok", caller: "me", operation: .browserHTML, selector: "main > input")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func browserRequestsAndRepliesRoundTripThroughControlServer() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let seen = Seen()
        let path = ControlEnvironment.socketPath(directory: directory)
        let tabs = ControlResponse(browserTabs: [ControlBrowserTab(id: "abcd1234", title: "Preview", url: nil, loading: false, active: true)])
        let console = ControlResponse(console: [ControlConsoleEntry(sequence: 10, level: "info", text: "Ready", timestamp: Date(timeIntervalSinceReferenceDate: 42))])
        let screenshot = ControlResponse(text: "/tmp/berth.png")
        let server = ControlServer(path: path, token: "secret") { request in
            seen.add(request)
            switch request.operation {
            case .browserTabs: return tabs
            case .browserConsole: return console
            case .browserScreenshot: return screenshot
            default: return .failure("Unexpected request")
            }
        }
        try server.start()
        defer { server.stop() }

        let requests = [
            ControlRequest(token: "secret", caller: "me", operation: .browserTabs),
            ControlRequest(token: "secret", caller: "me", operation: .browserConsole, tab: "abcd", since: 9),
            ControlRequest(token: "secret", caller: "me", operation: .browserScreenshot, tab: "abcd", path: "/tmp/berth.png", fullPage: true),
        ]
        for (request, response) in zip(requests, [tabs, console, screenshot]) {
            #expect(try ControlClient.send(request, socketPath: path) == response)
        }
        #expect(seen.all == requests)
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
        #expect(ControlInstall.hookCommand.hasPrefix(#"[ -z "$BERTH_TAB_ID" ] || printf '"#))
        #expect(!ControlInstall.hookCommand.contains("\n"))
        #expect(ControlInstall.hookCommand.count(where: { $0 == "%" }) == 1 && ControlInstall.hookCommand.contains("%s"))
        #expect(ControlInstall.hookCommand.count(where: { $0 == "'" }) == 2)
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
