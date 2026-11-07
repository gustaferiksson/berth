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
        return isPath ? URL(filePath: folder).lastPathComponent : terminalTitle
    }

    var folder: String {
        kind == .shell ? terminal.workingDirectory ?? cwd : cwd
    }
}

enum SidebarItem: Hashable {
    case tab(Tab.ID)
    case session(String)
}

@Observable
final class Store {
    static let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")

    let updater = AppUpdater()

    var tabs: [Tab] = [] {
        didSet { saveOpenTabs() }
    }
    var selectedTabID: Tab.ID? {
        didSet {
            if let oldValue { tabTouches[oldValue] = .now }
            if let oldValue, let sessionID = tabs.first(where: { $0.id == oldValue })?.sessionID { seenAt[sessionID] = .now }
            saveOpenTabs()
        }
    }
    var lockedSessionID: String?
    var missingFolder: String?
    var editingGroup: CustomGroup?
    var isStatsRequested = false
    var isSettingsRequested = false
    var isHarborShown = false {
        didSet {
            guard oldValue, !isHarborShown, let terminal = focusedTerminal else { return }
            DispatchQueue.main.async { terminal.requestFocus() }
        }
    }
    var deletingGroup: CustomGroup?
    var launcherMode: LauncherMode? {
        didSet {
            guard oldValue != nil, launcherMode == nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !isHarborShown else { return }
                focusedTerminal?.requestFocus()
            }
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
    private(set) var pinnedSessions: [SessionSummary] = []
    private(set) var liveBySession: [String: LiveSession] = [:]
    private(set) var backgroundShellIDs: Set<String> = []
    private(set) var seenAt = UserDefaults.standard.dictionary(forKey: "seenSessions") as? [String: Date] ?? [:] {
        didSet { if persistsTabs { UserDefaults.standard.set(seenAt, forKey: "seenSessions") } }
    }
    private(set) var flaggedIDs = Set(UserDefaults.standard.stringArray(forKey: "flaggedSessions") ?? []) {
        didSet { if persistsTabs { UserDefaults.standard.set(flaggedIDs.sorted(), forKey: "flaggedSessions") } }
    }
    var isAppActive = true {
        didSet {
            guard oldValue, !isAppActive, let sessionID = tabs.first(where: { $0.id == selectedTabID })?.sessionID else { return }
            seenAt[sessionID] = .now
        }
    }
    private(set) var hasScanned = false
    private(set) var theme = GhosttyTheme(values: GhosttyConfig.load().values)
    private(set) var pullRequestStates = Snapshot.fixturePullRequestStates
    private(set) var searchIndexVersion = 0
    private(set) var searchIndexing: (done: Int, total: Int)?
    @ObservationIgnored private(set) var searchIndex = TranscriptSearchIndex()

    @ObservationIgnored var persistsTabs = true
    @ObservationIgnored var lastKeyInput = Date.distantPast
    #if DEBUG
    @ObservationIgnored var probeOpenedClaude: [String] = []
    #endif
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
    @ObservationIgnored private var pinnedIDs = UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? [] {
        didSet { if persistsTabs { UserDefaults.standard.set(pinnedIDs, forKey: "pinnedSessions") } }
    }
    @ObservationIgnored var isPointerInSidebar = false {
        didSet { if !isPointerInSidebar { applyGroups() } }
    }
    @ObservationIgnored private var pullRequestsFetchedAt = Date.distantPast
    @ObservationIgnored private var pullRequestPolling: Task<Void, Never>?
    @ObservationIgnored private var waitingSessionIDs: Set<String>?
    @ObservationIgnored private var tabTouches: [Tab.ID: Date] = [:]
    @ObservationIgnored private var recentTabIDs: [Tab.ID] = []
    #if DEBUG
    @ObservationIgnored var fakeWaiting: Bool?
    @ObservationIgnored var fakeLiveSessions: [LiveSession] = []
    #endif

    func start(restoringTabs: Bool) {
        updater.workingSessions = { [weak self] in self?.workingSessionCount ?? 0 }
        updater.isIdle = { [weak self] in self?.isIdle ?? false }
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
                self?.unloadIdleTabs()
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
        if hasScanned {
            let seen = Dictionary(summaries.map { ($0.id, seenAt[$0.id] ?? .now) }) { first, _ in first }
            if seen != seenAt { seenAt = seen }

            let flagged = flaggedIDs.intersection(summaries.map(\.id))
            if flagged != flaggedIDs { flaggedIDs = flagged }
        }

        let split = SessionArchive.split(summaries, archivedAt: archivedAt)
        if hasScanned, split.kept != archivedAt { archivedAt = split.kept }
        archivedSessions = split.archived
        activeSessions = split.active
        let pins = SessionPins.split(split.active, pinned: pinnedIDs)
        if hasScanned, pins.kept != pinnedIDs { pinnedIDs = pins.kept }
        pinnedSessions = pins.pinned
        let fresh = grouping.groups(pins.rest)
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
        let links = Set((pinnedSessions + groups.flatMap(\.sessions)).compactMap(\.pullRequest))
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
            self.summaries = Snapshot.fixtureSessions ?? summaries
            repositoryRoots = roots
            for index in tabs.indices {
                guard let cwd = summaries.first(where: { $0.id == tabs[index].sessionID })?.cwd, cwd != tabs[index].cwd else { continue }
                tabs[index].cwd = cwd
            }
            hasScanned = true
            applyGroups()
            refreshLive()
            if searchIndexTask != nil { updateSearchIndex() }
            let unknown = self.summaries.contains { $0.pullRequest.map { pullRequestStates[$0.url] == nil } ?? false }
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
        // Claude reports `shell` only while idle; a turn shows `busy`, so keep the mark until it reports plain idle.
        backgroundShellIDs = Set(liveBySession.values.filter { $0.activity == .shell || $0.activity != .idle && backgroundShellIDs.contains($0.sessionId) }.map(\.sessionId))
        let claimed = Set(tabs.compactMap(\.sessionID))
        let orphans = live.filter { !claimed.contains($0.sessionId) && ProcessAncestry.isDescendant($0.pid, of: getpid()) }
        for session in orphans {
            guard let position = tabs.firstIndex(where: { tab in
                tab.kind == .claude && tab.cwd == session.cwd && tab.sessionID.map { liveBySession[$0] == nil } ?? true
                    && session.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) >= tab.opened } ?? false
            }) else { continue }
            tabs[position].sessionID = session.sessionId
        }
        let needsYou = NeedsYou.update(previous: waitingSessionIDs, live: Array(liveBySession.values), inBerth: Set(tabs.compactMap(\.sessionID)))
        waitingSessionIDs = needsYou.waiting
        NeedsYouAlerts.update(entered: needsYou.entered, needsYouCount: needsYou.needsYou.count, store: self)
    }

    func unloadIdleTabs() {
        refreshLive()
        let threshold = UserDefaults.standard.object(forKey: GeneralSettings.unloadIdleKey) == nil ? 14_400 : UserDefaults.standard.double(forKey: GeneralSettings.unloadIdleKey)
        let lastClaude = recentTabIDs.first { id in tabs.contains { $0.id == id && $0.kind == .claude } }
        let candidates = tabs.filter { $0.kind == .claude && $0.id != lastClaude }.compactMap { tab in tab.sessionID.map { (id: tab.id, sessionID: $0, touched: max(tab.opened, tabTouches[tab.id] ?? .distantPast)) } }
        let lastActivity = Dictionary(activeSessions.map { ($0.id, $0.lastActivity) }) { first, _ in first }
        for id in IdleTabs.unloadable(candidates, live: liveBySession, lastActivity: lastActivity, pinned: Set(pinnedIDs), selected: selectedTabID, now: .now, threshold: threshold) {
            close(id)
        }
    }

    private var fakeLive: [LiveSession] {
        #if DEBUG
        let statuses = fakeWaiting.map { [$0 ? #""status":"waiting","waitingFor":"permission""# : #""status":"busy""#] }
            ?? (UserDefaults.standard.bool(forKey: "snapshotFakeStatus") ? [#""status":"waiting","waitingFor":"permission""#, #""status":"busy""#, #""status":"shell""#] : [])
        return fakeLiveSessions + zip(groups.first { !$0.sessions.isEmpty }?.sessions ?? [], statuses).compactMap { session, status in
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

    var workingSessionCount: Int {
        tabs.compactMap(\.sessionID).filter { liveBySession[$0]?.activity == .working }.count
    }

    var isIdle: Bool {
        workingSessionCount == 0
            && lastKeyInput.timeIntervalSinceNow < -30
            && !terminals.contains { $0.title(terminalTitle: $0.terminal.title, sessionTitle: nil) == $0.terminal.title }
    }

    var selection: SidebarItem? {
        guard let tab = tabs.first(where: { $0.id == selectedTabID }) else { return nil }
        if let sessionID = tab.sessionID, activeSessions.contains(where: { $0.id == sessionID }) {
            return .session(sessionID)
        }
        return .tab(tab.id)
    }

    func activate(_ item: SidebarItem?) {
        guard let tab = tab(activating: item) else { return }
        selectedTabID = tab.id
        recentTabIDs = [tab.id] + recentTabIDs.filter { $0 != tab.id }
        isHarborShown = false
        tab.terminal.requestFocus()
    }

    private func tab(activating item: SidebarItem?) -> Tab? {
        if case let .tab(id) = item { return tabs.first { $0.id == id } }
        guard case let .session(id) = item,
              let session = (activeSessions + archivedSessions).first(where: { $0.id == id })
        else { return nil }
        if archivedAt[id] != nil { unarchive(id) }
        refreshLive()
        if let tab = tab(forSession: session.id) {
            guard liveBySession[session.id] == nil, tab.opened.timeIntervalSinceNow < -10 else { return tab }
            close(tab.id)
        }
        guard liveBySession[session.id].map({ $0.attachID != nil }) ?? true else {
            lockedSessionID = session.id
            return nil
        }
        openClaude(cwd: session.cwd, resuming: session.id)
        return tabs.first { $0.id == selectedTabID }
    }

    var currentCwd: String {
        tabs.first { $0.id == selectedTabID }?.folder ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var focusedTerminal: TerminalViewState? {
        tabs.first { $0.id == selectedTabID }?.terminal
    }

    var terminals: [Tab] {
        tabs.filter { $0.kind == .shell }
    }

    func openShell(cwd: String, command: String? = nil) {
        let id = UUID()
        tabs.append(Tab(id: id, kind: .shell, cwd: cwd, sessionID: nil, terminal: terminal(cwd: cwd, command: command) { [weak self] in self?.close(id) }))
        selectedTabID = id
    }

    func newTerminal() {
        launcherMode = nil
        openShell(cwd: currentCwd)
        activate(selectedTabID.map(SidebarItem.tab))
    }

    func switchTerminal() {
        launcherMode = nil
        let kind: Tab.Kind = !isHarborShown && tabs.first { $0.id == selectedTabID }?.kind == .shell ? .claude : .shell
        let recent = recentTabIDs.lazy.compactMap { id in self.tabs.first { $0.id == id && $0.kind == kind } }.first
        if let target = recent ?? tabs.last(where: { $0.kind == kind }) { return activate(.tab(target.id)) }
        if kind == .shell { newTerminal() }
    }

    var sidebarGroups: [(group: SessionGroup, tabs: [Tab])] {
        let listed = Set(activeSessions.map(\.id))
        let unlisted = tabs.filter { $0.kind == .claude && !($0.sessionID.map(listed.contains) ?? false) }
        let grouping = grouping
        let placed = Dictionary(grouping: unlisted) { SessionGroup(kind: grouping.kind(forFolder: $0.cwd, lastPrompt: $0.opened), sessions: []).id }
        let known = Set(groups.map(\.id))
        let extra = Array(Set(unlisted.map { grouping.kind(forFolder: $0.cwd, lastPrompt: $0.opened) }))
            .map { SessionGroup(kind: $0, sessions: []) }
            .filter { !known.contains($0.id) }
            .sorted { $0.id < $1.id }
        return SessionGrouping.place(groups.filter { $0.custom != nil }, among: extra + groups.filter { $0.custom == nil }).map { ($0, placed[$0.id] ?? []) }
    }

    var sidebarOrderedTabs: [Tab] {
        terminals + pinnedSessions.compactMap { tab(forSession: $0.id) } + sidebarGroups.flatMap { $0.tabs + $0.group.sessions.compactMap { tab(forSession: $0.id) } }
    }

    func selectTab(number: Int) {
        let candidates = sidebarOrderedTabs
        guard !candidates.isEmpty else { return }
        let target = number >= 9 ? candidates[candidates.count - 1] : candidates.indices.contains(number - 1) ? candidates[number - 1] : nil
        guard let target else { return }
        activate(.tab(target.id))
    }

    func cycleTab(by offset: Int) {
        let candidates = sidebarOrderedTabs
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0.id == selectedTabID } ?? 0
        activate(.tab(candidates[(current + offset + candidates.count) % candidates.count].id))
    }

    func openClaude(cwd: String, resuming sessionID: String? = nil) {
        #if DEBUG
        if Snapshot.launcherKeys != nil { return probeOpenedClaude.append(cwd) }
        #endif
        guard FileManager.default.fileExists(atPath: cwd) else {
            missingFolder = cwd
            return
        }
        let id = UUID()
        let session = sessionID ?? UUID().uuidString.lowercased()
        let attachID = liveBySession[session]?.attachID
        let environment = [ClaudeLaunch.sessionVariable: attachID ?? session]
        let command = ClaudeLaunch.command(attachID != nil ? .attach : sessionID == nil ? .new : .resume)
        tabs.append(Tab(id: id, kind: .claude, cwd: cwd, sessionID: session, terminal: terminal(cwd: cwd, command: command, environment: environment) { [weak self] in self?.close(id) }))
        selectedTabID = id
        recentTabIDs = [id] + recentTabIDs.filter { $0 != id }
    }

    private func terminal(cwd: String, command: String?, environment: [String: String] = [:], onClose: @escaping () -> Void) -> TerminalViewState {
        let terminal = TerminalViewState(controller: GhosttyConfig.controller)
        terminal.makePlatformView = { VisibleDropTerminalView(frame: .zero) }
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
        let current = Set(sidebarGroups.map(\.group.id) + [Sidebar.terminalsID])
        let others = (UserDefaults.standard.string(forKey: "collapsedGroups") ?? "").split(separator: "\n").map(String.init).filter { !current.contains($0) }
        let listed = current.filter { Sidebar.collapsedByDefault.contains($0) == expanded }.sorted()
        UserDefaults.standard.set((others + listed).joined(separator: "\n"), forKey: "collapsedGroups")
    }

    func archive(_ sessionID: String) {
        archivedAt[sessionID] = .now
        pinnedIDs.removeAll { $0 == sessionID }
        applyGroups()
        if let tab = tab(forSession: sessionID) { close(tab.id) }
    }

    func unarchive(_ sessionID: String) {
        archivedAt[sessionID] = nil
        applyGroups()
    }

    func isUnread(_ session: SessionSummary) -> Bool {
        guard let seen = seenAt[session.id], session.lastActivity > seen else { return false }

        let isViewed = isAppActive && tabs.first { $0.id == selectedTabID }?.sessionID == session.id
        return !isViewed && liveBySession[session.id]?.activity != .working
    }

    func markRead(_ sessionID: String) {
        seenAt[sessionID] = .now
    }

    func markUnread(_ sessionID: String) {
        seenAt[sessionID] = .distantPast
    }

    func flag(_ sessionID: String) {
        flaggedIDs.insert(sessionID)
    }

    func unflag(_ sessionID: String) {
        flaggedIDs.remove(sessionID)
    }

    func pin(_ sessionID: String) {
        guard !pinnedIDs.contains(sessionID) else { return }
        pinnedIDs.append(sessionID)
        applyGroups()
    }

    func unpin(_ sessionID: String) {
        pinnedIDs.removeAll { $0 == sessionID }
        applyGroups()
    }

    func movePin(_ sessionID: String, onto index: Int) {
        pinnedIDs = SessionPins.moving(pinnedIDs, sessionID, onto: index)
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
        recentTabIDs.removeAll { $0 == id }
        guard selectedTabID == id else { return }
        selectedTabID = recentTabIDs.first ?? tabs.last?.id
        guard !isHarborShown else { return }
        focusedTerminal?.requestFocus()
    }

    private struct SavedTab: Codable {
        let kind: Tab.Kind
        let cwd: String
        let sessionID: String?
        let isSelected: Bool?
    }

    func saveOpenTabs() {
        guard persistsTabs else { return }
        let saved = tabs.map { SavedTab(kind: $0.kind, cwd: $0.folder, sessionID: $0.sessionID, isSelected: $0.id == selectedTabID) }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "openTabs")
    }

    private func restoreOpenTabs() {
        guard let data = UserDefaults.standard.data(forKey: "openTabs"),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data)
        else { return }
        var selected: Tab.ID?
        for tab in saved {
            if tab.kind == .shell {
                openShell(cwd: tab.cwd)
            } else {
                guard let session = activeSessions.first(where: { $0.id == tab.sessionID }), liveBySession[session.id].map({ $0.attachID != nil }) ?? true, FileManager.default.fileExists(atPath: session.cwd) else { continue }
                openClaude(cwd: session.cwd, resuming: session.id)
            }
            if tab.isSelected == true { selected = selectedTabID }
        }
        activate((selected ?? tabs.first { $0.kind == .claude }?.id ?? tabs.first?.id).map(SidebarItem.tab))
    }
}
