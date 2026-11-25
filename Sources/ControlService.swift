import BerthCore
import Foundation
import GhosttyTerminal
import WebKit

@Observable
final class ControlService {
    static let enabledKey = "controlEnabled"
    static let directory = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.gustaf.berth").appending(path: "control").path
    static let cliTool = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "berth-cli")

    private static let exitsDirectory = directory + "/exits"
    private static let noBrowserSession = "Only a Claude session tab, or a terminal it opened, has a browser"
    private static let browserTabLeftSession = "The browser tab is no longer in this session"

    private(set) var failure: String?
    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var openedBy: [UUID: UUID] = [:]

    init(store: Store) {
        self.store = store
    }

    func update() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return stop() }
        guard server == nil else { return }

        try? ControlInstall.refreshInstalled(skillFile: ControlInstaller.skillFile, settingsFile: ControlInstaller.settingsFile)
        do {
            let token = try ControlEnvironment.persistentToken(directory: Self.directory)
            try? FileManager.default.removeItem(atPath: Self.exitsDirectory)
            let server = ControlServer(path: ControlEnvironment.socketPath(directory: Self.directory), token: token) { [weak self] request in
                await self?.handle(request) ?? .failure("Berth is quitting")
            }
            try server.start()
            self.token = token
            self.server = server
            failure = nil
        } catch {
            failure = "Couldn’t listen for the berth command: \(error)"
        }
    }

    func environment(for tab: UUID) -> [String: String] {
        guard server != nil else { return [:] }

        return ControlEnvironment.variables(socketPath: ControlEnvironment.socketPath(directory: Self.directory), token: token, tab: tab.uuidString)
    }

    private func stop() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: Self.directory + "/token")
        failure = nil
        openedBy = [:]
    }

    private func handle(_ request: ControlRequest) async -> ControlResponse {
        guard let caller = UUID(uuidString: request.caller), store.tabs.contains(where: { $0.id == caller }) else { return .failure("Unknown calling tab") }

        if request.operation == .list { return list(for: caller) }

        if request.operation == .open || request.operation == .openSession { return open(request, for: caller) }

        if request.operation == .openPath { return openPath(request, for: caller) }

        let isBrowserCommand = request.operation == .openURL || request.operation == .browserOpen || request.operation.isBrowser
        if isBrowserCommand, let session = browserSession(for: caller) {
            let summary = session.sessionID.flatMap { store.sessionsByID[$0] }
            let title = summary?.title ?? URL(filePath: session.cwd).lastPathComponent
            if let denial = await store.browser.access.authorize(key: BrowserModel.key(of: session), title: title) { return .failure(denial) }
        }

        if request.operation == .openURL || request.operation == .browserOpen { return openURL(request, for: caller) }

        if request.operation.isBrowser { return await browser(request, for: caller) }

        if request.operation == .showPullRequest {
            guard let number = request.pullRequest else { return .failure("Missing pull request number") }

            switch await store.showPullRequestInReview(number: number, repository: request.repository, repositoryPath: request.repositoryPath, in: caller) {
            case let .success(link): return ControlResponse(text: "Showing \(link.repository) PR #\(link.number) in Review")
            case let .failure(error): return .failure(error.message)
            }
        }

        guard let tab = request.tab else { return .failure("Missing tab") }

        let matches = store.tabs.filter { $0.id.uuidString.lowercased().hasPrefix(tab.lowercased()) }
        guard matches.count == 1, let target = matches.first else { return .failure(matches.isEmpty ? "No tab \(tab)" : "\(tab) matches more than one tab") }

        switch request.operation {
        case .capture: return await capture(target)

        case .wait: return await wait(for: target.id, timeout: request.timeout)

        default: break
        }
        guard openedBy[target.id] == caller else { return .failure("You can only send to or close tabs you opened") }

        if request.operation == .close {
            store.close(target.id, stopsTask: true)
            return ControlResponse()
        }

        store.lastKeyInput = .now
        guard target.terminal.paste(text: request.text ?? "") else { return .failure("The tab didn’t accept the text") }

        if request.enter != false { target.terminal.sendKey(.enter) }

        return ControlResponse()
    }

    private func list(for caller: UUID) -> ControlResponse {
        ControlResponse(tabs: store.tabs.map { tab in
            ControlTab(
                id: Self.shortID(tab.id),
                kind: tab.kind.rawValue,
                title: tab.title(terminalTitle: tab.terminal.title, sessionTitle: store.sessionTitle(of: tab)),
                cwd: tab.folder,
                session: tab.sessionID,
                status: tab.sessionID.flatMap { store.liveBySession[$0]?.status },
                openedByYou: openedBy[tab.id] == caller
            )
        })
    }

    private func open(_ request: ControlRequest, for caller: UUID) -> ControlResponse {
        let cwd = request.cwd ?? store.tabs.first { $0.id == caller }?.folder ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return .failure("No folder \(cwd)") }

        let id: UUID
        let previous = store.selectedTabID
        if request.operation == .openSession {
            guard let opened = store.openSession(cwd: cwd, checkout: .main, pasting: request.text, selectsTab: request.background != true) else { return .failure("Couldn’t open a Claude session in \(cwd)") }

            id = opened
        } else {
            id = UUID()
            let command = request.command.map { ControlExitStatus.wrapping($0, recordingIn: Self.exitsDirectory + "/" + id.uuidString) }
            try? FileManager.default.createDirectory(atPath: Self.exitsDirectory, withIntermediateDirectories: true)
            let callerTab = store.tabs.first { $0.id == caller }
            let parent = callerTab?.kind == .claude ? callerTab?.id : callerTab?.parentTabID
            store.openShell(cwd: cwd, command: command, id: id, parent: parent, taskTitle: request.command?.split(separator: "\n").first.map(String.init) ?? "Interactive terminal")
        }
        openedBy = openedBy.filter { opened in store.tabs.contains { $0.id == opened.key } }
        openedBy[id] = caller
        if request.background != true {
            store.activate(.tab(id))
        } else if request.operation == .open {
            store.selectedTabID = previous
        }
        return ControlResponse(tab: Self.shortID(id))
    }

    private func openPath(_ request: ControlRequest, for caller: UUID) -> ControlResponse {
        guard let path = request.path, path.hasPrefix("/") else { return .failure("Missing absolute path") }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .failure("No such path \(path)") }
        guard isDirectory.boolValue else { return .failure("\(path) is a file, and Berth opens folders only") }

        let id: UUID
        if let shown = store.tabs.first(where: { $0.kind == .claude && $0.folder == path }) {
            id = shown.id
        } else {
            guard let opened = store.openSession(cwd: path, checkout: .main, selectsTab: false) else { return .failure("Couldn’t open a Claude session in \(path)") }

            id = opened
            openedBy = openedBy.filter { opened in store.tabs.contains { $0.id == opened.key } }
            openedBy[id] = caller
        }
        if request.background != true { store.activate(.tab(id)) }
        return ControlResponse(tab: Self.shortID(id))
    }

    private func openURL(_ request: ControlRequest, for caller: UUID) -> ControlResponse {
        let url = request.url.flatMap(URL.init(string:))
        guard url.map(WebAddress.allows) == true || (request.operation == .browserOpen && request.url == nil) else { return .failure("Pass one http or https URL") }
        guard let session = browserSession(for: caller) else { return .failure(Self.noBrowserSession) }

        store.browser.open(url, in: BrowserModel.key(of: session), selects: request.background != true).isDrivenByAgent = true
        if request.background != true {
            store.activate(.tab(session.id))
            store.showBrowserPane()
        }
        return ControlResponse(text: "Opened \(url?.absoluteString ?? "a blank tab") in the session’s browser")
    }

    private func browserSession(for caller: UUID) -> Tab? {
        guard let tab = store.tabs.first(where: { $0.id == caller }) else { return nil }

        if tab.kind == .claude { return tab }

        return store.tabs.first { $0.kind == .claude && $0.id == tab.parentTabID }
    }

    private func browser(_ request: ControlRequest, for caller: UUID) async -> ControlResponse {
        guard let session = browserSession(for: caller) else { return .failure(Self.noBrowserSession) }

        let key = BrowserModel.key(of: session)
        let tabs = store.browser.tabs(in: key)
        let active = tabs.first { $0.id == store.browser.selectedIDs[key] } ?? tabs.last
        if request.operation == .browserTabs {
            return ControlResponse(browserTabs: tabs.map { tab in
                ControlBrowserTab(id: Self.shortID(tab.id), title: tab.displayTitle, url: tab.url?.absoluteString, loading: tab.isLoading, active: tab === active)
            })
        }

        let tab: BrowserTab
        if let id = request.tab {
            let matches = tabs.filter { !id.isEmpty && $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
            guard matches.count == 1, let match = matches.first else {
                return .failure(matches.isEmpty ? "No browser tab \(id) in this session" : "\(id) matches more than one browser tab in this session")
            }

            tab = match
        } else {
            guard let active else { return .failure("This session has no browser tabs. Open one with berth open-url.") }

            tab = active
        }

        tab.isDrivenByAgent = true
        switch request.operation {
        case .browserURL: return ControlResponse(text: tab.url?.absoluteString ?? "")

        case .browserReload:
            tab.reload()
            return ControlResponse()

        case .browserNavigate:
            guard let url = request.url.flatMap(URL.init(string:)), WebAddress.allows(url) else { return .failure("Pass one http or https URL") }

            tab.load(url)
            return ControlResponse()

        case .browserConsole: return tab.console(since: request.since)

        case .browserText, .browserHTML, .browserSnapshot:
            do {
                let content: BrowserPageContent = switch request.operation {
                case .browserHTML: .html(request.selector)
                case .browserSnapshot: .snapshot
                default: .text
                }
                let text = try await tab.pageContent(content)
                guard browserSessionContains(tab, session: session.id, caller: caller) else { return .failure(Self.browserTabLeftSession) }

                return ControlResponse(text: text)
            } catch {
                return .failure(error.localizedDescription)
            }

        case .browserScreenshot:
            guard let path = request.path, path.hasPrefix("/") else { return .failure("Missing absolute screenshot path") }

            do {
                let png = try await tab.screenshot(fullPage: request.fullPage == true, fallbackSize: store.browser.lastPaneSize)
                guard browserSessionContains(tab, session: session.id, caller: caller) else { return .failure(Self.browserTabLeftSession) }

                try png.write(to: URL(filePath: path), options: .atomic)
                return ControlResponse(text: path)
            } catch {
                return .failure(error.localizedDescription)
            }

        case .browserClick, .browserFill, .browserType, .browserPress, .browserSelect, .browserHover, .browserScroll, .browserWait, .browserBack, .browserForward, .browserEval:
            let response = await interact(request, with: tab) { self.browserSessionContains(tab, session: session.id, caller: caller) }
            guard browserSessionContains(tab, session: session.id, caller: caller) else { return .failure(Self.browserTabLeftSession) }

            return response

        default: return .failure("Unknown browser operation")
        }
    }

    private func interact(_ request: ControlRequest, with tab: BrowserTab, isInSession: @escaping () -> Bool) async -> ControlResponse {
        let view = tab.webView
        if view.window == nil, view.frame.isEmpty { view.setFrameSize(store.browser.lastPaneSize) }

        let canUseView = { isInSession() && view === tab.loadedWebView }
        let action = String(request.operation.rawValue.dropFirst("browser-".count))
        if request.operation == .browserWait {
            let response = await waitForPage(request, in: tab, view: view, canUseView: canUseView)
            return canUseView() ? response : .failure(Self.browserTabLeftSession)
        }

        await tab.waitForNavigation(in: view)
        guard canUseView() else { return .failure(Self.browserTabLeftSession) }

        let url = view.url
        let historyItem = view.backForwardList.currentItem
        let sequence = tab.navigationSequence
        do {
            if request.operation == .browserEval {
                guard let script = request.text else { return .failure("Missing JavaScript body") }

                let value = try await BrowserInteraction.evaluate(script, in: view)
                guard canUseView() else { return .failure(Self.browserTabLeftSession) }

                return ControlResponse(text: value)
            }
            let target: String?
            let notes: [String]?
            switch request.operation {
            case .browserBack, .browserForward:
                let back = request.operation == .browserBack
                guard back ? view.canGoBack : view.canGoForward else { return .failure("No page to go \(action) to") }

                _ = back ? view.goBack() : view.goForward()

                target = nil
                notes = nil

            default:
                let result = try await BrowserInteraction.perform(action, request: request, in: view)
                guard canUseView() else { return .failure(Self.browserTabLeftSession) }

                target = result.target
                notes = result.notes
            }
            try await Task.sleep(for: .milliseconds(300))
            guard canUseView() else { return .failure(Self.browserTabLeftSession) }

            let navigating = tab.isNavigating
            if navigating {
                await tab.waitForNavigation(in: view)
                guard canUseView() else { return .failure(Self.browserTabLeftSession) }
            }
            let navigated = navigating || tab.navigationSequence != sequence || view.url != url || view.backForwardList.currentItem !== historyItem
            return try BrowserInteraction.outcome(action, target: target, in: view, navigated: navigated, notes: notes)
        } catch {
            guard canUseView() else { return .failure(Self.browserTabLeftSession) }

            return .failure(error.localizedDescription)
        }
    }

    private func waitForPage(_ request: ControlRequest, in tab: BrowserTab, view: WKWebView, canUseView: () -> Bool) async -> ControlResponse {
        guard let condition = BrowserInteraction.Wait(request) else { return .failure("Pass one browser wait condition") }

        let url = view.url
        let sequence = tab.navigationSequence
        let start = ProcessInfo.processInfo.systemUptime
        let timeout = request.timeout ?? 10
        guard timeout.isFinite, timeout >= 0 else { return .failure("Pass a nonnegative timeout in seconds") }

        do {
            while true {
                let matched: Bool
                switch condition {
                case let .milliseconds(milliseconds):
                    matched = ProcessInfo.processInfo.systemUptime - start >= Double(milliseconds) / 1000 && Double(milliseconds) / 1000 <= timeout

                case let .url(substring):
                    matched = view.url?.absoluteString.contains(substring) ?? (!tab.isNavigating && "about:blank".contains(substring))

                case .load where tab.isNavigating: matched = false

                default:
                    matched = try await condition.matches(in: view, navigating: { tab.isNavigating })
                    guard canUseView() else { return .failure(Self.browserTabLeftSession) }
                }
                if matched {
                    return try BrowserInteraction.outcome("wait", target: condition.description, in: view, navigated: tab.navigationSequence != sequence || view.url != url)
                }
                let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
                guard remaining > 0 else { return .failure("Timed out waiting for \(condition.description)") }

                let delay = if case let .milliseconds(milliseconds) = condition {
                    min(0.1, remaining, max(0, Double(milliseconds) / 1000 - (ProcessInfo.processInfo.systemUptime - start)))
                } else {
                    min(0.1, remaining)
                }
                try await Task.sleep(for: .seconds(delay))
                guard canUseView() else { return .failure(Self.browserTabLeftSession) }
            }
        } catch {
            guard canUseView() else { return .failure(Self.browserTabLeftSession) }

            return .failure(error.localizedDescription)
        }
    }

    private func browserSessionContains(_ tab: BrowserTab, session: UUID, caller: UUID) -> Bool {
        guard let current = browserSession(for: caller), current.id == session else { return false }

        return store.browser.tabs(in: BrowserModel.key(of: current)).contains { $0 === tab }
    }

    private func capture(_ tab: Tab) async -> ControlResponse {
        guard tab.isHosted, let socket = store.hostSocket(of: tab.id) else {
            return .failure("Capture is unsupported for this tab: Berth can only read tabs opened with Keep sessions running when Berth quits on")
        }
        guard let bytes = await Task.detached(operation: { SessionHost.dump(socketPath: socket) }).value else { return .failure("The tab’s session host didn’t answer") }

        return ControlResponse(text: TerminalText.plain(bytes))
    }

    private func wait(for id: UUID, timeout: Double?) async -> ControlResponse {
        let file = Self.exitsDirectory + "/" + id.uuidString
        let deadline = timeout.map { Date.now.addingTimeInterval($0) }
        while store.tabs.contains(where: { $0.id == id }), !FileManager.default.fileExists(atPath: file) {
            if let deadline, Date.now > deadline { return .failure("Timed out") }

            try? await Task.sleep(for: .milliseconds(200))
        }
        defer { try? FileManager.default.removeItem(atPath: file) }

        guard let status = Self.terminalExitStatus(of: id) else { return .failure("The tab closed without an exit status") }

        if store.tabs.contains(where: { $0.id == id && $0.taskTitle != nil && $0.parentTabID != nil }) { store.terminalTaskExitStatuses[id] = status }
        return ControlResponse(exit: status)
    }

    static func terminalExitStatus(of id: UUID) -> Int32? {
        (try? String(contentsOfFile: exitsDirectory + "/" + id.uuidString, encoding: .utf8)).flatMap(Int32.init)
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}
