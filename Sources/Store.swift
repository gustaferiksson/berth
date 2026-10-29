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
    var cwd: String
    var sessionID: String?
    let terminal: TerminalViewState
    let opened = Date.now
}

extension Tab {
    func title(terminalTitle: String, sessionTitle: String?) -> String {
        if let sessionTitle { return sessionTitle }
        if kind == .claude { return terminalTitle.isEmpty ? "New Claude Session" : terminalTitle }
        let isPath = terminalTitle.isEmpty || terminalTitle.hasPrefix("/") || terminalTitle.hasPrefix("~")
        return isPath ? URL(filePath: terminal.workingDirectory ?? cwd).lastPathComponent : terminalTitle
    }
}

enum SidebarItem: Hashable {
    case tab(Tab.ID)
    case session(String)
}

private struct LauncherOrigin {
    let focusedShell: Tab.ID?
    let panelShell: Tab.ID?
    let tab: Tab.ID?
}

@Observable
final class Store {
    static let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")

    let updater = AppUpdater()

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
    var missingFolder: String?
    var editingGroup: CustomGroup?
    var isStatsRequested = false
    var isHarborShown = false {
        didSet {
            guard oldValue, !isHarborShown, let terminal = focusedTerminal else { return }
            DispatchQueue.main.async { terminal.requestFocus() }
        }
    }
    var deletingGroup: CustomGroup?
    var launcherMode: LauncherMode? {
        willSet {
            guard launcherMode == nil else { return }
            launcherOrigin = LauncherOrigin(focusedShell: shells.first { $0.terminal.isFocused }?.id, panelShell: isPanelOpen ? selectedShellID : nil, tab: selectedTabID)
        }
        didSet {
            guard launcherMode == nil else { return }
            let panelShell = isPanelOpen ? selectedShellID : nil
            let returnsToPanel = panelShell != nil && selectedTabID == launcherOrigin?.tab && (launcherOrigin?.focusedShell != nil || panelShell != launcherOrigin?.panelShell)
            launcherOrigin = nil
            guard !isHarborShown, let terminal = (returnsToPanel ? shells.first { $0.id == panelShell } : tabs.first { $0.id == selectedTabID })?.terminal else { return }
            DispatchQueue.main.async { terminal.requestFocus() }
        }
    }
    @ObservationIgnored var launcherQuery = Snapshot.launcherQuery
    var groupingMode = GroupingMode(rawValue: UserDefaults.standard.string(forKey: "groupingMode") ?? "") ?? .project {
        didSet {
            if persistsTabs { UserDefaults.standard.set(groupingMode.rawValue, forKey: "groupingMode") }
            applyGroups()
        }
    }
    var showsCustomGroups = UserDefaults.standard.object(forKey: "showsCustomGroups") == nil || UserDefaults.standard.bool(forKey: "showsCustomGroups") {
        didSet {
            if persistsTabs { UserDefaults.standard.set(showsCustomGroups, forKey: "showsCustomGroups") }
            applyGroups()
        }
    }
    var customGroups = (UserDefaults.standard.string(forKey: "customGroups")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CustomGroup].self, from: $0) } ?? [] {
        didSet {
            if persistsTabs, let data = try? JSONEncoder().encode(customGroups) { UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "customGroups") }
            applyGroups()
        }
    }
    private(set) var groups: [SessionGroup] = []
    private(set) var activeSessions: [SessionSummary] = []
    private(set) var archivedSessions: [SessionSummary] = []
    private(set) var liveBySession: [String: LiveSession] = [:]
    private(set) var hasScanned = false
    private(set) var theme = GhosttyTheme(values: GhosttyConfig.load().values)
    private(set) var pullRequestStates: [URL: PullRequestState] = [:]
    private(set) var searchIndexVersion = 0
    private(set) var searchIndexing: (done: Int, total: Int)?
    @ObservationIgnored private(set) var searchIndex = TranscriptSearchIndex()

    @ObservationIgnored var persistsTabs = true
    @ObservationIgnored private var index = TranscriptIndex(root: claudeDirectory.appending(path: "projects"))
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchIndexTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var themeWatcher: FileWatcher?
    @ObservationIgnored private var summaries: [SessionSummary] = []
    @ObservationIgnored private var groupOrder: [String] = []
    @ObservationIgnored private var repositoryRoots: [String: String] = [:]
    @ObservationIgnored private var archivedAt = UserDefaults.standard.dictionary(forKey: "archivedSessions") as? [String: Date] ?? [:] {
        didSet { if persistsTabs { UserDefaults.standard.set(archivedAt, forKey: "archivedSessions") } }
    }
    @ObservationIgnored var isPointerInSidebar = false {
        didSet { if !isPointerInSidebar { applyGroups() } }
    }
    @ObservationIgnored private var pullRequestsFetchedAt = Date.distantPast
    @ObservationIgnored private var pullRequestPolling: Task<Void, Never>?
    @ObservationIgnored private var waitingSessionIDs: Set<String>?
    @ObservationIgnored private var launcherOrigin: LauncherOrigin?
    #if DEBUG
    @ObservationIgnored var fakeWaiting: Bool?
    #endif

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
        activeSessions = split.active
        let fresh = grouping.groups(split.active)
        let folders = fresh.compactMap(\.folder)
        let known = Set(groupOrder)
        groupOrder = folders.filter { !known.contains($0) } + groupOrder.filter(folders.contains)
        let automatic = fresh.filter { $0.custom == nil && $0.folder == nil } + groupOrder.compactMap { folder in fresh.first { $0.folder == folder } }
        let ordered = SessionGrouping.place(fresh.filter { $0.custom != nil }, among: automatic)
        let previous = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        groups = ordered.map { group in
            guard isPointerInSidebar, let shown = previous[group.id] else { return group }
            let rank = Dictionary(uniqueKeysWithValues: shown.sessions.enumerated().map { ($1.id, $0) })
            return SessionGroup(kind: group.kind, sessions: group.sessions.sorted { rank[$0.id, default: -1] < rank[$1.id, default: -1] })
        }
    }

    var grouping: SessionGrouping {
        SessionGrouping(mode: groupingMode, customGroups: showsCustomGroups ? customGroups : [], repositoryRoots: repositoryRoots)
    }

    var knownFolders: [(path: String, sessions: Int, lastActivity: Date)] {
        Dictionary(grouping: activeSessions + archivedSessions, by: \.cwd)
            .map { (path: $0.key, sessions: $0.value.count, lastActivity: $0.value.map(\.lastActivity).max() ?? .distantPast) }
            .sorted { $0.lastActivity > $1.lastActivity }
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
            let (updated, summaries, roots) = await Task.detached { [roots = repositoryRoots] in
                var index = index
                let summaries = index.refresh()
                let unresolved = Set(summaries.map(\.cwd)).filter { roots[$0] == nil }
                return (index, summaries, roots.merging(unresolved.map { ($0, RepositoryRoot.resolve($0)) }) { $1 })
            }.value
            self.index = updated
            self.summaries = summaries
            repositoryRoots = roots
            for index in tabs.indices {
                guard let cwd = summaries.first(where: { $0.id == tabs[index].sessionID })?.cwd, cwd != tabs[index].cwd else { continue }
                tabs[index].cwd = cwd
            }
            hasScanned = true
            applyGroups()
            refreshLive()
            if searchIndexTask != nil { updateSearchIndex() }
            let unknown = summaries.contains { $0.pullRequest.map { pullRequestStates[$0.url] == nil } ?? false }
            if unknown { refreshPullRequests() }
        }
    }

    func updateSearchIndex() {
        searchIndexTask = Task { [previous = searchIndexTask, refreshTask] in
            await previous?.value
            await refreshTask?.value
            let sources = await Task.detached { [index] in index.searchSources }.value
            let stale = searchIndex.stale(sources).sorted { lhs, rhs in
                let (left, right) = (lhs.url.path.contains("/subagents/"), rhs.url.path.contains("/subagents/"))
                return left != right ? right : lhs.modified > rhs.modified
            }
            searchIndex.retain(sources)
            searchIndexing = stale.count > 10 ? (0, stale.count) : nil
            for start in stride(from: 0, to: stale.count, by: 10) {
                let batch = stale[start..<min(start + 10, stale.count)]
                searchIndex = await Task.detached { [searchIndex] in
                    batch.reduce(into: searchIndex) { $0.index($1) }
                }.value
                searchIndexing = start + batch.count < stale.count ? (start + batch.count, stale.count) : nil
                searchIndexVersion += 1
            }
            if searchIndexVersion == 0 { searchIndexVersion = 1 }
        }
    }

    func refreshLive() {
        let live = fakeLive + LiveSession.load(from: Self.claudeDirectory.appending(path: "sessions")) { kill($0, 0) == 0 || errno == EPERM }
        liveBySession = Dictionary(live.map { ($0.sessionId, $0) }) { first, _ in first }
        let needsYou = NeedsYou.update(previous: waitingSessionIDs, live: Array(liveBySession.values))
        waitingSessionIDs = needsYou.waiting
        NeedsYouAlerts.update(entered: needsYou.entered, waitingCount: needsYou.waiting.count, store: self)
        let claimed = Set(tabs.compactMap(\.sessionID))
        let orphans = live.filter { !claimed.contains($0.sessionId) && ProcessAncestry.isDescendant($0.pid, of: getpid()) }
        for session in orphans {
            guard let position = tabs.firstIndex(where: { tab in
                tab.kind == .claude && tab.cwd == session.cwd && tab.sessionID.map { liveBySession[$0] == nil } ?? true
                    && session.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) >= tab.opened } ?? false
            }) else { continue }
            tabs[position].sessionID = session.sessionId
        }
    }

    private var fakeLive: [LiveSession] {
        #if DEBUG
        let statuses = fakeWaiting.map { [$0 ? #""status":"waiting","waitingFor":"permission""# : #""status":"busy""#] }
            ?? (UserDefaults.standard.bool(forKey: "snapshotFakeStatus") ? [#""status":"waiting","waitingFor":"permission""#, #""status":"busy""#] : [])
        return zip(groups.first { !$0.sessions.isEmpty }?.sessions ?? [], statuses).compactMap { session, status in
            let json = #"{"pid":1,"sessionId":"\#(session.id)","cwd":"\#(session.cwd)",\#(status)}"#
            return try? JSONDecoder().decode(LiveSession.self, from: Data(json.utf8))
        }
        #else
        return []
        #endif
    }

    func sessionTitle(of tab: Tab) -> String? {
        guard let id = tab.sessionID else { return nil }
        return activeSessions.first { $0.id == id }?.title
    }

    func tab(forSession id: String) -> Tab? {
        tabs.first { $0.sessionID == id }
    }

    var selection: SidebarItem? {
        guard let tab = tabs.first(where: { $0.id == selectedTabID }) else { return nil }
        if let sessionID = tab.sessionID, activeSessions.contains(where: { $0.id == sessionID }) {
            return .session(sessionID)
        }
        return .tab(tab.id)
    }

    func activate(_ item: SidebarItem?) {
        guard let item else { return }
        if case let .tab(id) = item {
            selectedTabID = id
            isHarborShown = false
            return
        }
        guard case let .session(id) = item,
              let session = (activeSessions + archivedSessions).first(where: { $0.id == id })
        else { return }
        if archivedAt[id] != nil { unarchive(id) }
        refreshLive()
        if let tab = tab(forSession: session.id) {
            guard liveBySession[session.id] == nil, tab.opened.timeIntervalSinceNow < -10 else {
                selectedTabID = tab.id
                isHarborShown = false
                return
            }
            close(tab.id)
        }
        guard liveBySession[session.id] == nil else {
            lockedSessionID = session.id
            return
        }
        isHarborShown = false
        openClaude(cwd: session.cwd, resuming: session.id)
    }

    private var focusedShell: Tab? {
        shells.first { $0.terminal.isFocused || $0.id == launcherOrigin?.focusedShell }
    }

    var currentCwd: String {
        if let shell = focusedShell { return shell.terminal.workingDirectory ?? shell.cwd }
        return tabs.first { $0.id == selectedTabID }?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var focusedTerminal: TerminalViewState? {
        (focusedShell ?? tabs.first { $0.id == selectedTabID })?.terminal
    }

    func openShell(cwd: String, command: String? = nil) {
        let id = UUID()
        shells.append(Tab(id: id, kind: .shell, cwd: cwd, sessionID: nil, terminal: terminal(cwd: cwd, command: command) { [weak self] in self?.close(id) }))
        selectedShellID = id
        isPanelOpen = true
    }

    var sidebarGroups: [(group: SessionGroup, tabs: [Tab])] {
        let listed = Set(activeSessions.map(\.id))
        let unlisted = tabs.filter { !($0.sessionID.map(listed.contains) ?? false) }
        let grouping = grouping
        let placed = Dictionary(grouping: unlisted) { SessionGroup(kind: grouping.kind(forFolder: $0.cwd, lastActivity: $0.opened), sessions: []).id }
        let known = Set(groups.map(\.id))
        let extra = Array(Set(unlisted.map { grouping.kind(forFolder: $0.cwd, lastActivity: $0.opened) }))
            .map { SessionGroup(kind: $0, sessions: []) }
            .filter { !known.contains($0.id) }
            .sorted { $0.id < $1.id }
        return SessionGrouping.place(groups.filter { $0.custom != nil }, among: extra + groups.filter { $0.custom == nil }).map { ($0, placed[$0.id] ?? []) }
    }

    var sidebarOrderedTabs: [Tab] {
        sidebarGroups.flatMap { $0.tabs + $0.group.sessions.compactMap { tab(forSession: $0.id) } }
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
        if inPanel {
            selectedShellID = tab.id
        } else {
            selectedTabID = tab.id
            isHarborShown = false
        }
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

    func openClaude(cwd: String, resuming sessionID: String? = nil, prompt: String = "") {
        guard FileManager.default.fileExists(atPath: cwd) else {
            missingFolder = cwd
            return
        }
        let id = UUID()
        let session = sessionID ?? UUID().uuidString.lowercased()
        let environment = [ClaudeLaunch.sessionVariable: session, ClaudeLaunch.promptVariable: prompt].filter { !$0.value.isEmpty }
        let command = ClaudeLaunch.command(sessionID == nil ? .new : .resume, prompt: prompt)
        tabs.append(Tab(id: id, kind: .claude, cwd: cwd, sessionID: session, terminal: terminal(cwd: cwd, command: command, environment: environment) { [weak self] in self?.close(id) }))
        selectedTabID = id
    }

    private func terminal(cwd: String, command: String?, environment: [String: String] = [:], onClose: @escaping () -> Void) -> TerminalViewState {
        let terminal = TerminalViewState(controller: GhosttyConfig.controller)
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: cwd,
            envVars: environment,
            command: command,
            waitAfterCommand: false
        )
        terminal.onClose = { _ in onClose() }
        return terminal
    }

    func save(_ group: CustomGroup) {
        if let index = customGroups.firstIndex(where: { $0.id == group.id }) {
            customGroups[index] = group
        } else {
            customGroups.append(group)
        }
    }

    func addFolder(_ folder: String, to groupID: CustomGroup.ID) {
        guard let index = customGroups.firstIndex(where: { $0.id == groupID }), !customGroups[index].rules.contains(where: { $0.path == folder }) else { return }
        customGroups[index].rules.append(FolderRule(path: folder, includesSubfolders: false))
    }

    func moveGroup(from source: Int, to destination: Int) {
        let shown = sidebarGroups.map(\.group)
        guard showsCustomGroups, shown.indices.contains(source), shown[source].custom != nil else { return }
        let moved = SessionGrouping.moving(shown, from: source, to: min(max(destination, 0), shown.count))
        guard moved.count == customGroups.count else { return }
        customGroups = moved
    }

    func setGroupsExpanded(_ expanded: Bool) {
        guard persistsTabs else { return }
        let current = Set(sidebarGroups.map(\.group.id))
        let others = (UserDefaults.standard.string(forKey: "collapsedGroups") ?? "").split(separator: "\n").map(String.init).filter { !current.contains($0) }
        let listed = current.filter { Sidebar.collapsedByDefault.contains($0) == expanded }.sorted()
        UserDefaults.standard.set((others + listed).joined(separator: "\n"), forKey: "collapsedGroups")
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
        if let pid = tabs.first(where: { $0.id == id })?.sessionID.flatMap({ liveBySession[$0]?.pid }), ProcessAncestry.isDescendant(pid, of: getpid()) {
            for signal in [SIGHUP, SIGTERM] { kill(pid, signal) }
        }
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
        for tab in saved {
            if tab.kind == .shell {
                let wasOpen = isPanelOpen
                openShell(cwd: tab.cwd)
                isPanelOpen = wasOpen
                continue
            }
            guard let session = activeSessions.first(where: { $0.id == tab.sessionID }), liveBySession[session.id] == nil, FileManager.default.fileExists(atPath: session.cwd) else { continue }
            openClaude(cwd: session.cwd, resuming: session.id)
        }
    }
}
