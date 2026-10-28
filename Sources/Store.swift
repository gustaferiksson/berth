import BerthCore
import Darwin
import Foundation
import GhosttyTerminal
import Observation

struct Tab: Identifiable {
    enum Kind: String, Codable {
        case shell
        case claude
    }

    let id: UUID
    let kind: Kind
    let cwd: String
    var sessionID: String?
    let terminal: TerminalViewState
}

extension Tab {
    static let shellName = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "zsh").lastPathComponent

    func title(terminalTitle: String, sessionTitle: String?) -> String {
        if let sessionTitle { return sessionTitle }
        if kind == .claude { return terminalTitle.isEmpty ? "New Claude Session" : terminalTitle }
        let isPath = terminalTitle.isEmpty || terminalTitle.hasPrefix("/") || terminalTitle.hasPrefix("~")
        return isPath ? Self.shellName : terminalTitle
    }
}

enum SidebarItem: Hashable {
    case tab(Tab.ID)
    case session(String)
}

@Observable
final class Store {
    static let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    static let terminalsGroupID = "Terminals"

    var tabs: [Tab] = [] {
        didSet { saveOpenTabs() }
    }
    var selectedTabID: Tab.ID?
    var notice: String?
    private(set) var groups: [ProjectGroup] = []
    private(set) var liveBySession: [String: LiveSession] = [:]
    private(set) var hasScanned = false
    private(set) var theme = GhosttyTheme(values: GhosttyConfig.load().values)

    @ObservationIgnored var persistsTabs = true
    @ObservationIgnored private var index = TranscriptIndex(root: claudeDirectory.appending(path: "projects"))
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var themeWatcher: FileWatcher?

    func start(restoringTabs: Bool) {
        let sessions = Self.claudeDirectory.appending(path: "sessions").path
        watcher = FileWatcher(paths: [sessions, Self.claudeDirectory.appending(path: "projects").path], latency: 1) { [weak self] paths in
            guard let self else { return }
            if paths.allSatisfy({ $0.hasPrefix(sessions) }) {
                refreshLive()
            } else {
                refresh()
            }
        }
        themeWatcher = FileWatcher(paths: GhosttyConfig.directories, latency: 0.5) { [weak self] _ in self?.reloadTheme() }
        refresh()
        guard restoringTabs else { return }
        Task {
            await refreshTask?.value
            restoreOpenTabs()
        }
    }

    private func reloadTheme() {
        let values = GhosttyConfig.load().values
        theme = GhosttyTheme(values: values)
        GhosttyConfig.controller.setTerminalConfiguration(GhosttyConfig.colorConfiguration(values))
    }

    func waitForScan() async {
        await refreshTask?.value
    }

    func refresh() {
        refreshTask = Task { [previous = refreshTask, index] in
            await previous?.value
            let (updated, summaries) = await Task.detached {
                var index = index
                return (index, index.refresh())
            }.value
            self.index = updated
            groups = ProjectGroup.grouped(summaries)
            refreshLive()
            hasScanned = true
        }
    }

    func refreshLive() {
        let live = fakeLive + LiveSession.load(from: Self.claudeDirectory.appending(path: "sessions")) { kill($0, 0) == 0 || errno == EPERM }
        liveBySession = Dictionary(live.map { ($0.sessionId, $0) }) { first, _ in first }
        let claimed = Set(tabs.compactMap(\.sessionID))
        let orphans = live.filter { !claimed.contains($0.sessionId) && ProcessAncestry.isDescendant($0.pid, of: getpid()) }
        for session in orphans {
            guard let position = tabs.firstIndex(where: { tab in
                tab.kind == .claude && tab.cwd == session.cwd && tab.sessionID.map { liveBySession[$0] == nil } ?? true
            }) else { continue }
            tabs[position].sessionID = session.sessionId
        }
    }

    private var fakeLive: [LiveSession] {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "snapshotFakeStatus") else { return [] }
        let statuses = [#""status":"waiting","waitingFor":"permission""#, #""status":"busy""#]
        return zip(groups.first?.sessions ?? [], statuses).compactMap { session, status in
            let json = #"{"pid":1,"sessionId":"\#(session.id)","cwd":"\#(session.cwd)",\#(status)}"#
            return try? JSONDecoder().decode(LiveSession.self, from: Data(json.utf8))
        }
        #else
        return []
        #endif
    }

    func sessionTitle(of tab: Tab) -> String? {
        guard let id = tab.sessionID else { return nil }
        return groups.lazy.flatMap(\.sessions).first { $0.id == id }?.title
    }

    func tab(forSession id: String) -> Tab? {
        tabs.first { $0.sessionID == id }
    }

    var selection: SidebarItem? {
        guard let tab = tabs.first(where: { $0.id == selectedTabID }) else { return nil }
        if let sessionID = tab.sessionID, groups.contains(where: { group in group.sessions.contains { $0.id == sessionID } }) {
            return .session(sessionID)
        }
        return .tab(tab.id)
    }

    func activate(_ item: SidebarItem?) {
        guard let item else { return }
        if case let .tab(id) = item {
            selectedTabID = id
            return
        }
        guard case let .session(id) = item,
              let session = groups.lazy.flatMap(\.sessions).first(where: { $0.id == id })
        else { return }
        if let tab = tab(forSession: session.id) {
            selectedTabID = tab.id
            return
        }
        guard liveBySession[session.id] == nil else {
            notice = "“\(session.title)” is running in another terminal. Quit it there to open it here, so the transcript isn’t written by two processes."
            return
        }
        openClaude(cwd: session.cwd, resuming: session.id)
    }

    func openShell(cwd: String) {
        open(kind: .shell, cwd: cwd, sessionID: nil, command: nil)
    }

    func openClaude(cwd: String, resuming sessionID: String? = nil) {
        let id = sessionID ?? UUID().uuidString.lowercased()
        let flag = sessionID == nil ? "--session-id" : "--resume"
        open(kind: .claude, cwd: cwd, sessionID: id, command: "/bin/zsh -ilc 'claude \(flag) \(id); exec /bin/zsh -il'")
    }

    private func open(kind: Tab.Kind, cwd: String, sessionID: String?, command: String?) {
        let id = UUID()
        let terminal = TerminalViewState(controller: GhosttyConfig.controller)
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: cwd,
            command: command,
            waitAfterCommand: false
        )
        terminal.onClose = { [weak self] _ in self?.close(id) }
        tabs.append(Tab(id: id, kind: kind, cwd: cwd, sessionID: sessionID, terminal: terminal))
        selectedTabID = id
    }

    func close(_ id: Tab.ID) {
        tabs.removeAll { $0.id == id }
        if selectedTabID == id { selectedTabID = tabs.last?.id }
    }

    private struct SavedTab: Codable {
        let kind: Tab.Kind
        let cwd: String
        let sessionID: String?
    }

    private func saveOpenTabs() {
        guard persistsTabs else { return }
        let saved = tabs.map { SavedTab(kind: $0.kind, cwd: $0.cwd, sessionID: $0.sessionID) }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "openTabs")
    }

    private func restoreOpenTabs() {
        guard let data = UserDefaults.standard.data(forKey: "openTabs"),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data)
        else { return }
        let known = Set(groups.flatMap { $0.sessions.map(\.id) })
        for tab in saved {
            if tab.kind == .shell {
                openShell(cwd: tab.cwd)
                continue
            }
            guard let sessionID = tab.sessionID, known.contains(sessionID), liveBySession[sessionID] == nil else { continue }
            openClaude(cwd: tab.cwd, resuming: sessionID)
        }
    }
}
