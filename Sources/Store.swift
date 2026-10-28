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

    var tabs: [Tab] = [] {
        didSet { saveOpenTabs() }
    }
    var selectedTabID: Tab.ID?
    var shells: [Tab] = [] {
        didSet { saveOpenTabs() }
    }
    var selectedShellID: Tab.ID?
    var isPanelOpen = UserDefaults.standard.bool(forKey: "terminalPanelOpen") {
        didSet { if persistsTabs { UserDefaults.standard.set(isPanelOpen, forKey: "terminalPanelOpen") } }
    }
    var lockedSessionID: String?
    private(set) var groups: [ProjectGroup] = []
    private(set) var archivedSessions: [SessionSummary] = []
    private(set) var liveBySession: [String: LiveSession] = [:]
    private(set) var hasScanned = false
    private(set) var theme = GhosttyTheme(values: GhosttyConfig.load().values)
    private(set) var pullRequestStates: [URL: PullRequestState] = [:]

    @ObservationIgnored var persistsTabs = true
    @ObservationIgnored private var index = TranscriptIndex(root: claudeDirectory.appending(path: "projects"))
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var themeWatcher: FileWatcher?
    @ObservationIgnored private var summaries: [SessionSummary] = []
    @ObservationIgnored private var groupOrder: [String] = []
    @ObservationIgnored private var archivedAt = UserDefaults.standard.dictionary(forKey: "archivedSessions") as? [String: Date] ?? [:] {
        didSet { if persistsTabs { UserDefaults.standard.set(archivedAt, forKey: "archivedSessions") } }
    }
    @ObservationIgnored var isPointerInSidebar = false {
        didSet { if !isPointerInSidebar { applyGroups() } }
    }
    @ObservationIgnored private var pullRequestsFetchedAt = Date.distantPast
    @ObservationIgnored private var pullRequestPolling: Task<Void, Never>?

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
        pullRequestPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.refreshPullRequests()
            }
        }
        refresh()
        guard restoringTabs else { return }
        Task {
            await refreshTask?.value
            restoreOpenTabs()
        }
    }

    private func applyGroups() {
        let split = SessionArchive.split(summaries, archivedAt: archivedAt)
        if hasScanned, split.kept != archivedAt { archivedAt = split.kept }
        archivedSessions = split.archived
        let fresh = ProjectGroup.grouped(split.active)
        let known = Set(groupOrder)
        groupOrder = fresh.map(\.cwd).filter { !known.contains($0) } + groupOrder.filter { cwd in fresh.contains { $0.cwd == cwd } }
        let previous = Dictionary(uniqueKeysWithValues: groups.map { ($0.cwd, $0) })
        groups = groupOrder.compactMap { cwd in
            guard let group = fresh.first(where: { $0.cwd == cwd }) else { return nil }
            guard isPointerInSidebar, let shown = previous[cwd] else { return group }
            let rank = Dictionary(uniqueKeysWithValues: shown.sessions.enumerated().map { ($1.id, $0) })
            return ProjectGroup(cwd: cwd, sessions: group.sessions.sorted { rank[$0.id, default: -1] < rank[$1.id, default: -1] }, lastActivity: group.lastActivity)
        }
    }

    func refreshPullRequests() {
        let links = Set(groups.flatMap { $0.sessions.compactMap(\.pullRequest) })
        guard !links.isEmpty, pullRequestsFetchedAt.timeIntervalSinceNow < -60 else { return }
        pullRequestsFetchedAt = .now
        Task {
            let states = await Task.detached { await PullRequestStatus.fetch(links) }.value
            pullRequestStates.merge(states) { $1 }
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
            self.summaries = summaries
            hasScanned = true
            applyGroups()
            refreshLive()
            let unknown = summaries.contains { $0.pullRequest.map { pullRequestStates[$0.url] == nil } ?? false }
            if unknown { refreshPullRequests() }
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
              let session = (groups.flatMap(\.sessions) + archivedSessions).first(where: { $0.id == id })
        else { return }
        if archivedAt[id] != nil { unarchive(id) }
        if let tab = tab(forSession: session.id) {
            selectedTabID = tab.id
            return
        }
        guard liveBySession[session.id] == nil else {
            lockedSessionID = session.id
            return
        }
        openClaude(cwd: session.cwd, resuming: session.id)
    }

    var currentCwd: String {
        tabs.first { $0.id == selectedTabID }?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    func openShell(cwd: String, command: String? = nil) {
        let id = UUID()
        shells.append(Tab(id: id, kind: .shell, cwd: cwd, sessionID: nil, terminal: terminal(cwd: cwd, command: command) { [weak self] in self?.close(id) }))
        selectedShellID = id
        isPanelOpen = true
    }

    var sidebarOrderedTabs: [Tab] {
        let known = Set(groups.map(\.cwd))
        let cwds = Array(Set(tabs.map(\.cwd).filter { !known.contains($0) })).sorted() + groups.map(\.cwd)
        return cwds.flatMap { cwd in
            let sessions = groups.first { $0.cwd == cwd }?.sessions ?? []
            let listed = Set(sessions.map(\.id))
            let unlisted = tabs.filter { $0.cwd == cwd && !($0.sessionID.map(listed.contains) ?? false) }
            return unlisted + sessions.compactMap { tab(forSession: $0.id) }
        }
    }

    func selectTab(number: Int) {
        let isPanel = shells.contains { $0.terminal.isFocused }
        let candidates = isPanel ? shells : sidebarOrderedTabs
        guard !candidates.isEmpty else { return }
        let target = number >= 9 ? candidates[candidates.count - 1] : candidates.indices.contains(number - 1) ? candidates[number - 1] : nil
        guard let target else { return }
        focus(target, inPanel: isPanel)
    }

    func cycleTab(by offset: Int) {
        let isPanel = shells.contains { $0.terminal.isFocused }
        let candidates = isPanel ? shells : sidebarOrderedTabs
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0.id == (isPanel ? selectedShellID : selectedTabID) } ?? 0
        focus(candidates[(current + offset + candidates.count) % candidates.count], inPanel: isPanel)
    }

    private func focus(_ tab: Tab, inPanel: Bool) {
        if inPanel { selectedShellID = tab.id } else { selectedTabID = tab.id }
        DispatchQueue.main.async { tab.terminal.requestFocus() }
    }

    func toggleTerminalPanel() {
        if isPanelOpen {
            isPanelOpen = false
            tabs.first { $0.id == selectedTabID }?.terminal.requestFocus()
            return
        }
        if shells.isEmpty {
            openShell(cwd: currentCwd)
        } else {
            isPanelOpen = true
        }
        shells.first { $0.id == selectedShellID }?.terminal.requestFocus()
    }

    func openClaude(cwd: String, resuming sessionID: String? = nil) {
        let id = sessionID ?? UUID().uuidString.lowercased()
        let flag = sessionID == nil ? "--session-id" : "--resume"
        open(kind: .claude, cwd: cwd, sessionID: id, command: "/bin/zsh -ilc 'claude \(flag) \(id); exec /bin/zsh -il'")
    }

    private func open(kind: Tab.Kind, cwd: String, sessionID: String?, command: String?) {
        let id = UUID()
        tabs.append(Tab(id: id, kind: kind, cwd: cwd, sessionID: sessionID, terminal: terminal(cwd: cwd, command: command) { [weak self] in self?.close(id) }))
        selectedTabID = id
    }

    private func terminal(cwd: String, command: String?, onClose: @escaping () -> Void) -> TerminalViewState {
        let terminal = TerminalViewState(controller: GhosttyConfig.controller)
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: cwd,
            command: command,
            waitAfterCommand: false
        )
        terminal.onClose = { _ in onClose() }
        return terminal
    }

    func archive(_ sessionID: String) {
        archivedAt[sessionID] = .now
        applyGroups()
        if let tab = tab(forSession: sessionID) { close(tab.id) }
    }

    func unarchive(_ sessionID: String) {
        archivedAt[sessionID] = nil
        applyGroups()
    }

    func close(_ id: Tab.ID) {
        let processes = ProcessAncestry.descendants()
        Task {
            try? await Task.sleep(for: .seconds(1))
            ProcessAncestry.hangUpOrphans(of: processes)
            try? await Task.sleep(for: .seconds(1))
            refreshLive()
        }
        tabs.removeAll { $0.id == id }
        if selectedTabID == id { selectedTabID = tabs.last?.id }
        shells.removeAll { $0.id == id }
        if selectedShellID == id { selectedShellID = shells.last?.id }
        if shells.isEmpty, isPanelOpen { isPanelOpen = false }
    }

    private struct SavedTab: Codable {
        let kind: Tab.Kind
        let cwd: String
        let sessionID: String?
    }

    private func saveOpenTabs() {
        guard persistsTabs else { return }
        let saved = (tabs + shells).map { SavedTab(kind: $0.kind, cwd: $0.cwd, sessionID: $0.sessionID) }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "openTabs")
    }

    private func restoreOpenTabs() {
        guard let data = UserDefaults.standard.data(forKey: "openTabs"),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data)
        else { return }
        let known = Set(groups.flatMap { $0.sessions.map(\.id) })
        for tab in saved {
            if tab.kind == .shell {
                let wasOpen = isPanelOpen
                openShell(cwd: tab.cwd)
                isPanelOpen = wasOpen
                continue
            }
            guard let sessionID = tab.sessionID, known.contains(sessionID), liveBySession[sessionID] == nil else { continue }
            openClaude(cwd: tab.cwd, resuming: sessionID)
        }
    }
}
