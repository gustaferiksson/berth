import AppKit
import BerthCore
import CoreGraphics
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
    var agent = Agent.claude
    var parentTabID: Self.ID?
    let terminal: TerminalViewState
    let opened = Date.now
    var isHosted = false
}

extension Tab {
    func title(terminalTitle: String, sessionTitle: String?) -> String {
        if let sessionTitle { return sessionTitle }
        let terminalTitle = agent.harness.isStatusTitle(terminalTitle) ? "" : terminalTitle
        if kind == .claude { return terminalTitle.isEmpty ? "New \(agent.name) Session" : terminalTitle }
        let isPath = terminalTitle.isEmpty || terminalTitle.hasPrefix("/") || terminalTitle.hasPrefix("~")
        return isPath ? URL(filePath: folder).lastPathComponent : terminalTitle
    }

    var folder: String {
        kind == .shell && !isHosted ? terminal.workingDirectory ?? cwd : cwd
    }
}

enum SidebarItem: Hashable {
    case tab(Tab.ID)
    case session(String)
    case task(String)
}

enum NewSessionCheckout {
    case preferred, main, worktree
}

enum PullRequestPrompt {
    case summarize, steward

    func text(for link: PullRequestLink, url: URL) -> String {
        switch self {
        case .summarize:
            (UserDefaults.standard.string(forKey: GeneralSettings.pullRequestPromptKey) ?? GeneralSettings.defaultPullRequestPrompt)
                .replacing("{number}", with: String(link.number))
                .replacing("{url}", with: url.absoluteString)
                .replacing("{repo}", with: link.repository)

        case .steward: "/steward \(url.absoluteString)"
        }
    }
}

enum PullRequestOpening {
    case session(SessionSummary)
    case tab(Tab.ID)
    case worktree(String)
    case noCheckout

    var isOpenable: Bool {
        if case .noCheckout = self { return false }

        return true
    }
}

struct ReviewRepository: Hashable {
    let root: String
    let folder: String
    let isEdited: Bool

    var name: String { URL(filePath: root).lastPathComponent }
}

@Observable
final class Store {
    static let shared = Store()
    static let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    static let codexDirectory = CodexIndex.home(environment: ProcessInfo.processInfo.environment, user: FileManager.default.homeDirectoryForCurrentUser)

    let updater = AppUpdater()
    @ObservationIgnored lazy var remote = RemoteServer(store: self)
    @ObservationIgnored lazy var control = ControlService(store: self)
    @ObservationIgnored lazy var browser = BrowserModel(store: self)

    var tabs: [Tab] = [] {
        didSet {
            saveOpenTabs()
            prepareReviewModel()
            syncConversations()
        }
    }

    var selectedTabID: Tab.ID? {
        didSet {
            if let oldValue { tabTouches[oldValue] = .now }
            if let oldValue, let sessionID = tabs.first(where: { $0.id == oldValue })?.sessionID { seenAt[sessionID] = .now }
            if let selected = tabs.first(where: { $0.id == selectedTabID }), let parent = selected.parentTabID { paneTerminalIDs[parent] = selected.id }
            if selectedTabID != oldValue {
                endTerminalSearch()
                refreshEditedRepositories()
            }
            saveOpenTabs()
            prepareReviewModel()
            syncConversations()
        }
    }

    var lockedSessionID: String?
    var sessionPanes: [Tab.ID: SessionPane] = [:]
    var paneTerminalIDs: [Tab.ID: Tab.ID] = [:]
    var conversationTabIDs: Set<Tab.ID> = [] {
        didSet { syncConversations() }
    }

    var conversationSuspended: Set<Tab.ID> = [] {
        didSet { syncConversations() }
    }

    var conversationDrafts: [Tab.ID: ConversationDraft] = [:]
    @ObservationIgnored var conversationSlashCommands: [ConversationSlashPicker.Scope: [SlashCommand]] = [:]
    private(set) var conversationModels: [Tab.ID: ConversationModel] = [:]
    @ObservationIgnored private var recentConversationModels: [Tab.ID: (model: ConversationModel, sessionID: String?, agent: Agent, shownAt: ContinuousClock.Instant)] = [:]
    var conversationFocusRequests = 0
    private(set) var orphanedSessionIDs: Set<String> = []
    @ObservationIgnored private var resumingOrphans: Set<String> = []
    var sidebarCursor: SidebarItem?
    var multiSelection: [SidebarItem] = []
    @ObservationIgnored private var multiSelectionAnchor: SidebarItem?
    var missingFolder: String?
    var pullRequestFailure: String?
    var showPullRequestFailure: String?
    var stopWatchingFailure: String?
    private(set) var preparingPullRequests: [PullRequestLink] = []
    @ObservationIgnored private var pullRequestPreparation: Task<Void, Never>?
    var editingGroup: CustomGroup?
    var isStatsRequested = false
    var planUsage: PlanUsage?
    var codexUsage: CodexUsage?
    var isSettingsRequested = false
    var isHarborShown = false {
        didSet {
            if isHarborShown { endTerminalSearch() }
            syncConversations()
            guard oldValue, !isHarborShown else { return }

            DispatchQueue.main.async { [weak self] in self?.focusSelected() }
        }
    }

    var rendersMarkdown = UserDefaults.standard.bool(forKey: "rendersMarkdown") {
        didSet {
            if persistsTabs { UserDefaults.standard.set(rendersMarkdown, forKey: "rendersMarkdown") }
        }
    }

    var showsReviewPanel = UserDefaults.standard.bool(forKey: "showsReviewPanel") {
        didSet {
            if persistsTabs { UserDefaults.standard.set(showsReviewPanel, forKey: "showsReviewPanel") }
            prepareReviewModel()
            refreshEditedRepositories()
        }
    }

    var isReviewDiffUnified = false
    var isReviewTextFocused = false
    @ObservationIgnored private var reviewWatchers: [FileWatcher] = []
    @ObservationIgnored private var repositoryWatcher: FileWatcher?
    @ObservationIgnored private var reviewReload: Task<Void, Never>?
    @ObservationIgnored private var reviewIgnored: [String: [String]] = [:]
    @ObservationIgnored private var editedTask: Task<Void, Never>?
    @ObservationIgnored private var editedTranscripts: [String: (url: URL, edits: TranscriptEdits)] = [:]
    var editedRepositories: [String: [String: String]] = [:]
    var editedFiles: [String: [String]] = [:]
    static let sessionFilesRoot = "session-files"
    static let resolvedHome = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath().path
    private(set) var reviewRepositories: [String: [ReviewRepository]] = [:]
    private(set) var shownReviewPullRequests: [String: [PullRequestLink: ReviewPullRequest]] = [:]
    var activeReviewRoots: [String: String] = [:]
    var collapsedReviewRepositories: Set<String> = []
    var expandedReviewTasks: Set<String> = []
    var reviewRepoTabs: [String: String] = [:]
    var reviewModels: [String: ReviewModel] = [:] {
        didSet {
            for (id, model) in oldValue where reviewModels[id] !== model { model.language?.stop() }
        }
    }

    var terminalSearch: TerminalSearch? {
        didSet {
            guard let terminalSearch, terminalSearch.needle != oldValue?.needle else { return }

            terminalSearch.terminal.performBindingAction("search:\(terminalSearch.needle)")
        }
    }

    var deletingGroup: CustomGroup?
    var launcherMode: LauncherMode? {
        didSet {
            if launcherMode != .pullRequests { launcherRole = nil }
            guard oldValue != nil, launcherMode == nil else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, !isHarborShown, terminalSearch == nil else { return }

                focusSelected()
            }
        }
    }

    var sidebarFilter = ""
    var sidebarStatus = SidebarStatus.all
    var sidebarFilterFocusRequests = 0
    @ObservationIgnored var launcherQuery = Snapshot.launcherQuery
    var launcherRole: InboxPullRequest.Role?
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

    var showsTriage = UserDefaults.standard.bool(forKey: "showsTriage") {
        didSet { if persistsTabs { UserDefaults.standard.set(showsTriage, forKey: "showsTriage") } }
    }

    var customGroups = (UserDefaults.standard.string(forKey: "customGroups")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([CustomGroup].self, from: $0) } ?? [] {
        didSet {
            if persistsTabs, let data = try? JSONEncoder().encode(customGroups) { UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "customGroups") }
            applyGroups()
        }
    }

    private(set) var tasks = Snapshot.fixtureTasks ?? TaskState.stored(UserDefaults.standard.string(forKey: "tasks")).state {
        didSet {
            if persistsTabs { UserDefaults.standard.set(tasks.storage(keeping: unreadableTasks), forKey: "tasks") }
        }
    }

    private(set) var sessionTasks: [SessionTask] = []
    private(set) var liveSessions: [SessionSummary] = []
    private(set) var taskSuggestions: [String: TaskSuggestion] = [:]
    private(set) var groups: [SessionGroup] = []
    private(set) var activeSessions: [SessionSummary] = []
    private(set) var archivedSessions: [SessionSummary] = []
    private(set) var snoozedSessions: [SessionSummary] = []
    private(set) var pinnedSessions: [SessionSummary] = []
    private(set) var sessionsByID: [String: SessionSummary] = [:]
    private(set) var liveBySession: [String: LiveSession] = [:]
    private(set) var backgroundShellIDs: Set<String> = []
    private(set) var turnStarts = TurnStarts()
    private(set) var seenAt = UserDefaults.standard.dictionary(forKey: "seenSessions") as? [String: Date] ?? [:] {
        didSet { if persistsTabs { UserDefaults.standard.set(seenAt, forKey: "seenSessions") } }
    }

    @ObservationIgnored private var listedIDs = Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, Set(UserDefaults.standard.stringArray(forKey: "\($0.rawValue)SessionIDs") ?? [])) }) {
        didSet {
            guard persistsTabs else { return }

            for (agent, ids) in listedIDs where ids != oldValue[agent] { UserDefaults.standard.set(ids.sorted(), forKey: "\(agent.rawValue)SessionIDs") }
        }
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
    private(set) var theme = GhosttyTheme(values: GhosttyConfig.appliedValues)
    private(set) var pullRequests = Snapshot.fixturePullRequests
    private(set) var linkedPullRequests = Snapshot.fixtureLinkedPullRequests
    private(set) var inbox = Snapshot.fixtureInbox
    private(set) var isInboxLoading = Snapshot.launcherLoading
    private(set) var issueInbox = Snapshot.fixtureIssueInbox
    private(set) var isIssueInboxLoading = Snapshot.launcherLoading
    let projects = ProjectsModel()
    private var pullRequestTabs: [PullRequestLink: Tab.ID] = [:]
    private(set) var searchIndexVersion = 0
    private(set) var searchIndexing: (done: Int, total: Int)?
    @ObservationIgnored private(set) var searchIndex = TranscriptSearchIndex()

    @ObservationIgnored var persistsTabs = true
    @ObservationIgnored var lastKeyInput = Date.distantPast
    @ObservationIgnored var submittingSessions: Set<String> = []

    #if DEBUG
    @ObservationIgnored var probeOpened: [(agent: Agent, cwd: String, start: LaunchStart, prompt: String?)] = []
    @ObservationIgnored var probeOpenedURLs: [URL] = []
    #endif

    @ObservationIgnored var watchActivities: [String: (url: URL, activity: TranscriptActivity)] = [:]
    @ObservationIgnored var watchScan: Task<Void, Never>?
    @ObservationIgnored var watchScanRequested = false
    @ObservationIgnored var watchExpiry: Task<Void, Never>?
    var transcriptWatches: [String: PullRequestWatch] = [:]
    @ObservationIgnored private(set) var index = TranscriptIndex(root: claudeDirectory.appending(path: "projects"))
    @ObservationIgnored private(set) var codexIndex = CodexIndex(root: codexDirectory)

    @ObservationIgnored private var codexWatcher: FileWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var searchIndexTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var themeWatcher: FileWatcher?
    @ObservationIgnored private var summaries: [SessionSummary] = []
    @ObservationIgnored private var shownTasks: [StoredTask] = []
    @ObservationIgnored private var unreadableTasks = TaskState.stored(UserDefaults.standard.string(forKey: "tasks")).unreadable
    @ObservationIgnored private var groupOrder: [String] = []
    @ObservationIgnored private var repositoryRoots: [String: String] = [:]
    @ObservationIgnored private var checkouts: [String: String] = [:]
    @ObservationIgnored private var catalogModels: [String: (window: Int?, name: String?)] = [:]
    private var repositories = Snapshot.fixtureRepositories
    private var siblingClones: [String: [String: String]] = [:]
    @ObservationIgnored private var scannedCloneRoots: Set<String> = []
    @ObservationIgnored private var clonesScannedAt = Date.distantPast
    @ObservationIgnored private var cloneScan: Task<Void, Never>?
    @ObservationIgnored private var archivedAt = UserDefaults.standard.dictionary(forKey: "archivedSessions") as? [String: Date] ?? [:] {
        didSet { if persistsTabs { UserDefaults.standard.set(archivedAt, forKey: "archivedSessions") } }
    }

    private(set) var dismissedFailures = UserDefaults.standard.dictionary(forKey: "dismissedFailures") as? [String: String] ?? [:] {
        didSet { if persistsTabs { UserDefaults.standard.set(dismissedFailures, forKey: "dismissedFailures") } }
    }

    @ObservationIgnored private var snoozes = (UserDefaults.standard.dictionary(forKey: "snoozedSessions") ?? [:]).compactMapValues(SessionSnooze.init(stored:)) {
        didSet {
            if persistsTabs { UserDefaults.standard.set(snoozes.mapValues(\.stored), forKey: "snoozedSessions") }
            scheduleSnoozeWake()
        }
    }

    @ObservationIgnored private var snoozeWake: Task<Void, Never>?
    @ObservationIgnored private var pinnedIDs = UserDefaults.standard.stringArray(forKey: "pinnedSessions") ?? [] {
        didSet { if persistsTabs { UserDefaults.standard.set(pinnedIDs, forKey: "pinnedSessions") } }
    }

    @ObservationIgnored var isPointerInSidebar = false {
        didSet { if !isPointerInSidebar { applyGroups() } }
    }

    @ObservationIgnored private var pullRequestsFetchedAt = Date.distantPast
    @ObservationIgnored private var inboxFetchedAt = Date.distantPast
    @ObservationIgnored private var issueInboxFetchedAt = Date.distantPast
    @ObservationIgnored private var planUsageFetchedAt = Date.distantPast
    @ObservationIgnored private var codexUsageReadAt = Date.distantPast
    @ObservationIgnored private var planUsageResetRefetch: Task<Void, Never>?
    @ObservationIgnored private var pullRequestPolling: Task<Void, Never>?
    @ObservationIgnored private var tabSignalPolling: Task<Void, Never>?
    @ObservationIgnored private var hostedDirectoryPolling: Task<Void, Never>?
    @ObservationIgnored private var waitingSessionIDs: Set<String>?
    @ObservationIgnored private var tabTouches: [Tab.ID: Date] = [:]
    @ObservationIgnored private var restoredTabIDs: Set<Tab.ID> = []
    @ObservationIgnored var isTerminating = false
    @ObservationIgnored private var recentTabIDs: [Tab.ID] = []

    #if DEBUG
    @ObservationIgnored var fakeWaiting: Bool?
    @ObservationIgnored var fakeLiveSessions: [LiveSession] = []
    @ObservationIgnored var fakeTerminalTasks: [String: [RemoteTask]] = [:]
    var fakeWatches: [String: PullRequestWatch] = [:]
    @ObservationIgnored var fakeContexts: [String: SessionContext] = [:]
    #endif

    func start(restoringTabs: Bool) {
        updater.busySessions = { [weak self] in self?.busySessionCount ?? 0 }
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
        themeWatcher = FileWatcher(paths: GhosttyConfig.watchedPaths, latency: 0.5) { [weak self] changed in
            guard changed.contains(where: { $0.contains("/ghostty") || $0.contains("/berth/ghostty") }) else { return }

            self?.reloadTheme()
        }
        scheduleSnoozeWake()
        pullRequestPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.refreshPullRequests()
                self?.refreshInbox()
                self?.refreshIssueInbox()
                self?.projects.refresh()
                self?.refreshLocalClones()
                self?.unloadIdleTabs()
                await self?.refreshPlanUsage()
                await self?.refreshCodexUsage()
            }
        }
        tabSignalPolling?.cancel()
        tabSignalPolling = Task { [weak self] in
            while await (try? Task.sleep(for: .seconds(2))) != nil, !Task.isCancelled, let self {
                if tabs.contains(where: { $0.agent.harness.liveSource == .tabSignals && $0.sessionID != nil }) {
                    refreshLive()
                }
            }
        }
        hostedDirectoryPolling?.cancel()
        hostedDirectoryPolling = Task { [weak self] in
            while await (try? Task.sleep(for: .seconds(2))) != nil, !Task.isCancelled, let self {
                await refreshHostedDirectories()
            }
        }
        applyCodexSetting()
        refreshInbox()
        refreshIssueInbox()
        projects.refresh()
        Task {
            await refreshPlanUsage()
            await refreshCodexUsage()
        }
        guard restoringTabs else { return }

        browser.restore()
        Task {
            await refreshTask?.value
            await restoreOpenTabs()
        }
    }

    private func applyGroups() {
        let enabled = Agent.allCases.filter(Self.isEnabled)
        if hasScanned {
            let listed = Dictionary(uniqueKeysWithValues: enabled.map { agent in (agent, Set(summaries.filter { $0.agent == agent }.map(\.id))) })
            let merged = listedIDs.merging(listed) { _, new in new }
            if merged != listedIDs { listedIDs = merged }
        }
        let retained = hasScanned ? Set(Agent.allCases.filter { !enabled.contains($0) }.flatMap { listedIDs[$0] ?? [] }) : []
        if hasScanned {
            let seen = Dictionary(summaries.map { ($0.id, seenAt[$0.id] ?? .now) }) { first, _ in first }
                .merging(seenAt.filter { retained.contains($0.key) }) { first, _ in first }
            if seen != seenAt { seenAt = seen }

            let flagged = flaggedIDs.intersection(summaries.map(\.id)).union(flaggedIDs.intersection(retained))
            if flagged != flaggedIDs { flaggedIDs = flagged }
        }

        let split = SessionArchive.split(summaries, archivedAt: archivedAt)
        let keptArchive = split.kept.merging(archivedAt.filter { retained.contains($0.key) }) { first, _ in first }
        if hasScanned, keptArchive != archivedAt { archivedAt = keptArchive }
        if split.archived != archivedSessions { archivedSessions = split.archived }
        if split.active != activeSessions { activeSessions = split.active }
        let byID = Dictionary((split.active + split.archived).map { ($0.id, $0) }) { first, _ in first }
        if byID != sessionsByID { sessionsByID = byID }
        let selected = multiSelection.filter { item in if case let .session(id) = item { byID[id] != nil } else { true } }
        if selected != multiSelection { multiSelection = selected }
        let waiting = Set(liveBySession.values.filter { if case .needsInput = $0.activity { true } else { false } }.map(\.sessionId))
        let snooze = SessionTriage.split(split.active, snoozes: snoozes, waiting: waiting, now: .now)
        let keptSnoozes = snooze.kept.merging(snoozes.filter { retained.contains($0.key) }) { first, _ in first }
        if hasScanned {
            if keptSnoozes != snoozes { snoozes = keptSnoozes }
            for id in snooze.woken { seenAt[id] = .distantPast }
        }
        if snooze.snoozed != snoozedSessions { snoozedSessions = snooze.snoozed }
        let pins = SessionPins.split(snooze.awake, pinned: pinnedIDs)
        let keptPins = pinnedIDs.filter { pins.kept.contains($0) || retained.contains($0) }
        if hasScanned, keptPins != pinnedIDs { pinnedIDs = keptPins }
        if pins.pinned != pinnedSessions { pinnedSessions = pins.pinned }
        let live = grouping.active(snooze.awake, live: liveBySession)
        let liveRank = Dictionary(uniqueKeysWithValues: liveSessions.enumerated().map { ($1.id, $0) })
        let shownLive = isPointerInSidebar ? live.sorted { liveRank[$0.id, default: -1] < liveRank[$1.id, default: -1] } : live
        if shownLive != liveSessions { liveSessions = shownLive }
        let restByID = Dictionary(pins.rest.map { ($0.id, $0) }) { first, _ in first }
        let issueTitles = Dictionary(pullRequests.values.compactMap(\.self).flatMap(\.closingIssues).map { ($0.ref, $0.title) }) { first, _ in first }
        let rows = shownTasks.compactMap { task -> SessionTask? in
            let members = task.sessionIDs.compactMap { restByID[$0] }.sorted { $0.lastPrompt > $1.lastPrompt }
            guard let newest = members.first else { return nil }

            return SessionTask(id: task.id, title: task.name ?? task.issue.flatMap { issueTitles[$0] } ?? newest.title, issue: task.issue, sessions: members)
        }
        if rows != sessionTasks { sessionTasks = rows }
        let fresh = grouping.groups(pins.rest)
        let folders = fresh.compactMap(\.folder)
        let known = Set(groupOrder)
        groupOrder = folders.filter { !known.contains($0) } + groupOrder.filter(folders.contains)
        let automatic = fresh.filter { $0.custom == nil && $0.folder == nil } + groupOrder.compactMap { folder in fresh.first { $0.folder == folder } }
        let ordered = SessionGrouping.place(fresh.filter { $0.custom != nil }, among: automatic)
        let previous = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let shownGroups = ordered.map { group in
            guard isPointerInSidebar, let shown = previous[group.id] else { return group }

            let rank = Dictionary(uniqueKeysWithValues: shown.sessions.enumerated().map { ($1.id, $0) })
            return SessionGroup(kind: group.kind, sessions: group.sessions.sorted { rank[$0.id, default: -1] < rank[$1.id, default: -1] })
        }
        if shownGroups != groups { groups = shownGroups }
    }

    func formTasks() {
        guard hasScanned else { return }

        let result = TaskFormation.form(tasks, sessions: summaries.map(taskSession))
        if result.state != tasks { tasks = result.state }
        shownTasks = result.shown
        let suggestions = Dictionary(result.suggestions.flatMap { suggestion in suggestion.sessionIDs.map { ($0, suggestion) } }) { first, _ in first }
        if suggestions != taskSuggestions { taskSuggestions = suggestions }
        applyGroups()
        prepareReviewModel()
    }

    private func taskSession(_ session: SessionSummary) -> TaskSession {
        let root = repositoryRoots[session.checkout]
        let repository = root.flatMap { repositories[$0] ?? nil }?.lowercased() ?? root
        let looked = pullRequestBranches(of: session).lazy.compactMap { branch in (self.pullRequests[branch] ?? nil).map { (repository: branch.repository, pullRequest: $0) } }.first { $0.pullRequest.state != .closed }
        let link = looked.map { PullRequestLink(repository: $0.repository, number: $0.pullRequest.number) }
        let links = session.pullRequests + (link.flatMap { session.pullRequests.contains($0) ? nil : [$0] } ?? [])
        return TaskSession(
            id: session.id,
            lastPrompt: session.lastPrompt,
            repository: repository,
            repositories: Set([repository].compactMap(\.self) + links.map { $0.repository.lowercased() }),
            typedIssues: session.issueRefs,
            closingIssues: looked?.pullRequest.closingIssues.map(\.ref) ?? [],
            pullRequests: links,
            branches: session.branches
        )
    }

    func state(of issue: IssueRef) -> IssueState? {
        pullRequests.values.compactMap(\.self).flatMap(\.closingIssues).first { $0.ref == issue }?.state
    }

    func title(of task: StoredTask) -> String {
        let issueTitles = Dictionary(pullRequests.values.compactMap(\.self).flatMap(\.closingIssues).map { ($0.ref, $0.title) }) { first, _ in first }
        let newest = task.sessionIDs.compactMap { sessionsByID[$0] }.max { $0.lastPrompt < $1.lastPrompt }
        return task.name ?? task.issue.flatMap { issueTitles[$0] } ?? newest?.title ?? "Task"
    }

    func pullRequestCount(of members: [SessionSummary], in task: StoredTask) -> Int {
        Set(members.flatMap { currentPullRequests(of: $0, in: task) }.map { "\($0.repository.lowercased())#\($0.number)" }).count
    }

    private func currentPullRequests(of session: SessionSummary, in task: StoredTask?) -> [SessionPullRequest] {
        PullRequestSelection.current(pullRequests(of: session), branch: session.branches.first) { candidate in
            task?.issue.map { issue in candidate.pullRequest.closingIssues.contains { $0.ref == issue } } ?? false
        }
    }

    func repositoryRoot(ofSession sessionID: String) -> String? {
        sessionsByID[sessionID].flatMap { repositoryRoots[$0.checkout] }
    }

    func task(containing sessionID: String) -> StoredTask? {
        shownTasks.first { $0.sessionIDs.contains(sessionID) }
    }

    func renameTask(_ id: String, to name: String) {
        tasks.rename(id, to: name)
        formTasks()
    }

    func removeFromTask(_ sessionID: String) {
        guard let task = task(containing: sessionID) else { return }

        tasks.remove(sessionID, from: task.id)
        formTasks()
    }

    func openSessionIDs(inTask id: String) -> [String] {
        (tasks.tasks.first { $0.id == id }?.sessionIDs ?? []).filter { sessionID in activeSessions.contains { $0.id == sessionID } }
    }

    func markTaskDone(_ id: String) {
        for sessionID in openSessionIDs(inTask: id) { archive(sessionID) }
    }

    func markTaskNotDone(containing sessionID: String) {
        for id in task(containing: sessionID)?.sessionIDs ?? [] where archivedSessions.contains(where: { $0.id == id }) { unarchive(id) }
    }

    func deleteTask(_ id: String) {
        guard let task = tasks.tasks.first(where: { $0.id == id }) else { return }

        let keys = Set(summaries.filter { task.sessionIDs.contains($0.id) }.flatMap { taskSession($0).keys })
        tasks.delete(id, dismissing: keys)
        formTasks()
    }

    func accept(_ suggestion: TaskSuggestion) {
        if let taskID = suggestion.taskID {
            tasks.join(suggestion.sessionIDs, to: taskID)
        } else {
            tasks.makeTask(suggestion.sessionIDs, origin: .auto)
        }
        formTasks()
    }

    func dismiss(_ suggestion: TaskSuggestion) {
        tasks.dismissed.insert(suggestion.key)
        formTasks()
    }

    func newTask(from sessionIDs: [String]) {
        tasks.makeTask(sessionIDs, origin: .local)
        formTasks()
    }

    var grouping: SessionGrouping {
        SessionGrouping(mode: groupingMode, customGroups: showsCustomGroups ? customGroups : [], repositoryRoots: repositoryRoots)
    }

    var knownFolders: [(path: String, sessions: Int, lastActivity: Date)] {
        Dictionary(grouping: activeSessions + archivedSessions, by: \.checkout)
            .map { (path: $0.key, sessions: $0.value.count, lastActivity: $0.value.map(\.lastActivity).max() ?? .distantPast) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    func refreshPullRequests() {
        guard Snapshot.output == nil else { return }

        #if DEBUG
        guard !Snapshot.usesBusySidebar else { return }

        #endif

        let sessions = pinnedSessions + groups.flatMap(\.sessions) + archivedSessions
        let branches = Set(sessions.flatMap(pullRequestBranches))
        let watched = transcriptWatches.compactMap { id, watch -> PullRequestLink? in
            guard let number = watch.number,
                  let repo = watch.repository ?? sessionsByID[id].flatMap({ repositoryRoots[$0.checkout] }).flatMap({ repositories[$0] ?? nil })
            else { return nil }

            return PullRequestLink(repository: repo.lowercased(), number: number)
        }
        let linked = Set((sessions.flatMap(\.pullRequests) + watched).filter { [nil, .open, .draft].contains(linkedPullRequests[$0]?.state) })
        guard !branches.isEmpty || !linked.isEmpty, pullRequestsFetchedAt.timeIntervalSinceNow < -60 else { return }

        pullRequestsFetchedAt = .now
        Task { await fetchPullRequests(branches, linked: linked) }
    }

    func fetchPullRequests(_ branches: Set<PullRequestBranch>, linked: Set<PullRequestLink> = []) async {
        let fetched = await Task.detached { await PullRequestStatus.fetch(branches, linked: linked) }.value
        let merged = pullRequests.merging(fetched.branches) { $1 }
        if merged != pullRequests { pullRequests = merged }
        let mergedLinked = linkedPullRequests.merging(fetched.linked) { $1 }
        if mergedLinked != linkedPullRequests { linkedPullRequests = mergedLinked }
        formTasks()
    }

    func refreshPlanUsage() async {
        guard Snapshot.output == nil, UserDefaults.standard.bool(forKey: PlanUsageFetch.enabledKey) else { return }

        let resetSinceFetch = planUsage?.windows.contains { $0.resetsAt.map { $0 > planUsageFetchedAt && $0 <= .now } ?? false } ?? false
        guard planUsageFetchedAt.timeIntervalSinceNow < -60 || resetSinceFetch else { return }

        planUsageFetchedAt = .now
        let usage = await Task.detached { await PlanUsageFetch.fetch() }.value
        guard let usage else { return }

        planUsage = usage
        planUsageResetRefetch?.cancel()
        guard let nextReset = usage.windows.compactMap(\.resetsAt).filter({ $0 > .now }).min() else { return }

        planUsageResetRefetch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(nextReset.timeIntervalSinceNow + 5))
            guard !Task.isCancelled else { return }

            await self?.refreshPlanUsage()
        }
    }

    func refreshCodexUsage() async {
        guard Snapshot.output == nil else { return }
        guard UserDefaults.standard.bool(forKey: PlanUsageFetch.enabledKey), isCodexEnabled else {
            codexUsage = nil
            codexUsageReadAt = .distantPast
            return
        }
        guard codexUsageReadAt.timeIntervalSinceNow < -20 else { return }

        codexUsageReadAt = .now
        let usage = await Task.detached { [directory = Self.codexDirectory] in CodexUsage.latest(in: directory) }.value
        if usage != codexUsage { codexUsage = usage }
    }

    func refreshInbox() {
        guard Snapshot.output == nil, inboxFetchedAt.timeIntervalSinceNow < -60 else { return }

        inboxFetchedAt = .now
        isInboxLoading = true
        Task {
            let fetched = await Task.detached { PullRequestStatus.inbox() }.value
            if let fetched, fetched != inbox { inbox = fetched }
            isInboxLoading = false
        }
    }

    func refreshIssueInbox() {
        guard Snapshot.output == nil, !isIssueInboxLoading, issueInboxFetchedAt.timeIntervalSinceNow < -60 else { return }

        issueInboxFetchedAt = .now
        isIssueInboxLoading = true
        Task {
            let fetched = await Task.detached { PullRequestStatus.issueInbox() }.value
            if let fetched, fetched != issueInbox { issueInbox = fetched }
            isIssueInboxLoading = false
        }
    }

    func refreshLocalClones() {
        guard Snapshot.output == nil, cloneScan == nil else { return }

        let roots = Set(summaries.compactMap { repositoryRoots[$0.checkout] })
        guard roots != scannedCloneRoots || clonesScannedAt.timeIntervalSinceNow < -300 else { return }

        cloneScan = Task {
            let found = await Task.detached { await RepositoryRoot.gitHubSiblingClones(of: roots) }.value
            if siblingClones != found { siblingClones = found }
            scannedCloneRoots = roots
            clonesScannedAt = .now
            cloneScan = nil
            refreshLocalClones()
        }
    }

    func waitForLocalClones() async {
        while let cloneScan, !Task.isCancelled { await cloneScan.value }
    }

    func sessions(for pullRequest: PullRequestLink) -> [SessionSummary] {
        let repository = pullRequest.repository.lowercased()
        return (activeSessions + archivedSessions)
            .filter { session in
                session.pullRequests.contains { $0.number == pullRequest.number && $0.repository.lowercased() == repository }
                    || self.pullRequests(of: session).contains { $0.number == pullRequest.number && $0.repository.lowercased() == repository }
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    func opening(of pullRequest: PullRequestLink, prompt: PullRequestPrompt = .summarize) -> PullRequestOpening {
        let matching = sessions(for: pullRequest)
        if prompt == .summarize, let session = matching.first { return .session(session) }
        let claude = matching.filter { $0.agent == .claude }
        if let session = claude.first(where: { tab(forSession: $0.id) != nil }) { return .session(session) }
        let repository = pullRequest.repository.lowercased()
        let link = PullRequestLink(repository: repository, number: pullRequest.number)
        if let id = pullRequestTabs[link], tabs.contains(where: { $0.id == id }) { return .tab(id) }

        if let session = claude.first { return .session(session) }

        return localCheckout(of: repository).map(PullRequestOpening.worktree) ?? .noCheckout
    }

    func localCheckout(of repository: String) -> String? {
        let repository = repository.lowercased()
        if let root = knownFolders.lazy.compactMap({ self.repositoryRoots[$0.path] }).first(where: { root in
            (self.repositories[root] ?? nil)?.lowercased() == repository && FileManager.default.fileExists(atPath: root)
        }) { return root }

        return siblingClones.keys.sorted().lazy
            .flatMap { self.siblingClones[$0, default: [:]].filter { $0.value == repository }.keys.sorted() }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    @discardableResult
    func openPullRequest(_ link: PullRequestLink, url: URL, opening: PullRequestOpening, prompt: PullRequestPrompt = .summarize, selectsTab: Bool = true) -> Bool {
        let existing: SidebarItem
        switch opening {
        case let .session(session): existing = .session(session.id)
        case let .tab(id): existing = .tab(id)
        case .noCheckout: return false
        case let .worktree(root):
            let key = PullRequestLink(repository: link.repository.lowercased(), number: link.number)
            guard !preparingPullRequests.contains(key) else { return true }

            if opensAreProbed { return startPullRequestSession(key, in: root, url: url, prompt: prompt, selectsTab: selectsTab) }

            preparingPullRequests.append(key)
            let previous = pullRequestPreparation
            pullRequestPreparation = Task {
                await previous?.value
                defer { preparingPullRequests.removeAll { $0 == key } }

                do {
                    let path: String
                    if let worktrunk = PullRequestStatus.worktrunk {
                        path = try await PullRequestCheckout.prepare(root: root, number: key.number, worktrunk: worktrunk)
                    } else {
                        let head = await Task.detached { PullRequestStatus.head(of: key) }.value
                        guard let head else {
                            pullRequestFailure = "Couldn’t read the head branch of PR #\(key.number). Check that the GitHub CLI (gh) is signed in."
                            return
                        }

                        path = try await PullRequestCheckout.prepare(root: root, number: key.number, head: head)
                    }
                    startPullRequestSession(key, in: path, url: url, prompt: prompt, selectsTab: selectsTab)
                } catch {
                    pullRequestFailure = (error as? PullRequestCheckout.Failure)?.message ?? "Couldn’t prepare a worktree for PR #\(key.number)."
                }
            }
            return true
        }
        guard activate(existing, selectsTab: selectsTab) else { return false }
        guard prompt == .steward else { return true }

        let reused: Tab? = switch existing {
        case let .session(id): tab(forSession: id)
        case let .tab(id): tabs.first { $0.id == id }
        default: nil
        }
        guard let tab = reused, tab.agent == .claude, let sessionID = tab.sessionID else {
            pullRequestFailure = "Open the Claude session first, then choose Steward with Claude again"
            return false
        }

        if selectedTabID == tab.id { setConversation(false) }
        Task { await paste(prompt.text(for: link, url: url), intoStartingSession: sessionID, tab: tab.id) }
        return true
    }

    private var opensAreProbed: Bool {
        #if DEBUG
        Snapshot.showsPullRequestActions || Snapshot.launcherKeys != nil || Snapshot.issueQuery != nil || Snapshot.issueInboxQuery != nil || UserDefaults.standard.string(forKey: "snapshotOrphan") != nil || UserDefaults.standard.bool(forKey: "snapshotControl")
        #else
        false
        #endif
    }

    @discardableResult
    private func startPullRequestSession(_ key: PullRequestLink, in folder: String, url: URL, prompt: PullRequestPrompt, selectsTab: Bool) -> Bool {
        let text = prompt.text(for: key, url: url)
        guard let id = openSession(cwd: folder, checkout: .main, pasting: text.isEmpty ? nil : text, selectsTab: selectsTab) else { return false }

        pullRequestTabs[key] = id
        if selectsTab {
            isHarborShown = false
            if prompt == .steward, selectedTabID == id { setConversation(false) }
        }
        return true
    }

    func issuePullRequestStatus(_ pullRequest: LinkedPullRequest, opening: PullRequestOpening) -> String {
        switch opening {
        case let .session(session): tab(forSession: session.id) == nil ? "Resume Session" : "Switch To Session"
        case .tab: "Switch To Session"
        case .worktree: preparingPullRequests.contains(PullRequestLink(repository: pullRequest.link.repository.lowercased(), number: pullRequest.link.number)) ? "Preparing Worktree" : "New Worktree"
        case .noCheckout: "No local checkout of \(pullRequest.link.repository)"
        }
    }

    private func resolvePullRequests() {
        let unresolved = Set(summaries.compactMap { repositoryRoots[$0.checkout] } + reviewRepositories.values.flatMap { $0.map(\.root) }).filter { repositories[$0] == nil }
        Task {
            if !unresolved.isEmpty { await repositories.merge(Task.detached { await RepositoryRoot.gitHubRepositories(of: unresolved) }.value) { $1 } }
            formTasks()
            let sessions = pinnedSessions + groups.flatMap(\.sessions) + archivedSessions
            if sessions.flatMap(pullRequestBranches).contains(where: { pullRequests[$0] == nil }) || sessions.flatMap(\.pullRequests).contains(where: { linkedPullRequests[$0] == nil }) { refreshPullRequests() }
        }
    }

    func pullRequests(of session: SessionSummary) -> [SessionPullRequest] {
        let repository = repositoryRoots[session.checkout].flatMap { repositories[$0] ?? nil }
        let linked = session.pullRequests.compactMap { link in linkedPullRequests[link].map { SessionPullRequest(repository: link.repository, pullRequest: $0, head: $0.headRefName) } }
        let looked = repository.map { repository in session.branches.compactMap { branch in (pullRequests[PullRequestBranch(repository: repository, branch: branch)] ?? nil).map { SessionPullRequest(repository: repository, pullRequest: $0, head: branch) } } } ?? []
        return PullRequestSelection.order(linked + looked, currentRepository: repository, branches: session.branches)
    }

    func pullRequestWatch(for sessionID: String) -> PullRequestWatch? {
        #if DEBUG
        if let fixture = fakeWatches[sessionID] { return fixture }
        #endif
        guard let watch = transcriptWatches[sessionID], let live = liveBySession[sessionID],
              watch.since >= (live.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast),
              Date.now < watch.expiresAt
        else { return nil }

        let session = sessionsByID[sessionID]
        let repo = watch.repository ?? session.flatMap { repositoryRoots[$0.checkout] }.flatMap { repositories[$0] ?? nil }
        let target = if let number = watch.number {
            repo.flatMap { linkedPullRequests[PullRequestLink(repository: $0.lowercased(), number: number)] }
                ?? session.flatMap { pullRequests(of: $0).first { $0.number == number && (repo == nil || $0.repository.lowercased() == repo?.lowercased()) }?.pullRequest }
        } else {
            session.flatMap { pullRequest(for: $0) }
        }
        if let target, [.merged, .closed].contains(target.state) {
            if watch.number != nil || target.closedAt.map({ $0 >= watch.since }) == true { return nil }

            return watch
        }
        return PullRequestWatch(number: watch.number ?? target?.number, repository: repo, since: watch.since)
    }

    func pullRequest(for session: SessionSummary) -> PullRequest? {
        pullRequests(of: session).first?.pullRequest
    }

    func pullRequestTarget(forSession sessionID: String) -> (repository: String, pullRequest: PullRequest)? {
        guard let first = sessionsByID[sessionID].flatMap({ pullRequests(of: $0).first }) else { return nil }

        return (first.repository, first.pullRequest)
    }

    func pullRequest(in folder: String, branch: String) -> (repository: String, pullRequest: PullRequest?)? {
        guard let repository = repositoryRoots[folder].flatMap({ repositories[$0] ?? nil }), let pullRequest = pullRequests[PullRequestBranch(repository: repository, branch: branch)] else { return nil }

        return (repository, pullRequest)
    }

    private func pullRequestBranches(of session: SessionSummary) -> [PullRequestBranch] {
        guard let repository = repositoryRoots[session.checkout].flatMap({ repositories[$0] ?? nil }) else { return [] }

        let branches = session.branches.map { PullRequestBranch(repository: repository, branch: $0) }
        guard let found = branches.firstIndex(where: { (pullRequests[$0] ?? nil) != nil }) else { return branches }

        return Array(branches[...found])
    }

    private func reloadTheme() {
        GhosttyConfig.reload()
        let values = GhosttyConfig.appliedValues
        theme = GhosttyTheme(values: values)
        GhosttyConfig.controller.setTerminalConfiguration(GhosttyConfig.colorConfiguration(values))
    }

    func waitForScan() async {
        await refreshTask?.value
    }

    func sessionIndex(for agent: Agent) -> any SessionIndex {
        switch agent {
        case .claude: index
        case .codex: codexIndex
        }
    }

    private func agentDirectory(for agent: Agent) -> URL {
        switch agent {
        case .claude: Self.claudeDirectory
        case .codex: Self.codexDirectory
        }
    }

    func refresh() {
        #if DEBUG
        let fakeContexts = fakeContexts
        #else
        let fakeContexts: [String: SessionContext] = [:]
        #endif
        let claudeEnabled = Self.isEnabled(.claude)
        let codexEnabled = isCodexEnabled
        refreshTask = Task { [previous = refreshTask, index, startingCodex = codexIndex] in
            await previous?.value
            let (updated, updatedCodex, summaries, roots, checkouts, catalog) = await Task.detached { [roots = repositoryRoots, checkouts = checkouts, known = catalogModels, fixtures = Snapshot.fixtureSessions, catalogDirectory = Self.claudeDirectory.appending(path: "cache/model-catalog")] () -> (TranscriptIndex, CodexIndex, [SessionSummary], [String: String], [String: String], [String: (window: Int?, name: String?)]) in
                var index = index
                var codex = startingCodex
                let refreshed = (claudeEnabled ? index.refresh() : []) + (codexEnabled ? codex.refresh() : [])
                let unchecked = Set((fixtures ?? refreshed).map(\.cwd)).filter { checkouts[$0] == nil && FileManager.default.fileExists(atPath: $0) }
                let checkouts = checkouts.merging(unchecked.map { ($0, RepositoryRoot.checkout($0)) }) { $1 }
                let missing = Set(refreshed.filter { $0.agent.harness.supports(.contextSize) && $0.context?.window == nil }.compactMap(\.context?.model)).subtracting(known.keys)
                let catalogs = missing.isEmpty ? [] : ((try? FileManager.default.contentsOfDirectory(at: catalogDirectory, includingPropertiesForKeys: nil)) ?? []).compactMap { try? Data(contentsOf: $0) }
                let catalog = known.merging(missing.map { ($0, TranscriptActivity.catalogModel($0, catalogs: catalogs)) }) { $1 }
                let summaries = (fixtures ?? refreshed).map { summary in
                    var summary = summary
                    summary.checkout = checkouts[summary.cwd] ?? summary.originalCwd ?? summary.cwd
                    let resolvesWindow = summary.agent.harness.supports(.contextSize) && summary.context?.window == nil
                    let model = resolvesWindow ? summary.context.flatMap { catalog[$0.model] } : nil
                    if resolvesWindow {
                        summary.context?.window = model?.window
                        summary.context?.modelName = model?.name
                    }
                    summary.context = fakeContexts[summary.id] ?? summary.context
                    return summary
                }
                let unresolved = Set(summaries.map(\.checkout)).filter { roots[$0] == nil }
                return (index, codex, summaries, roots.merging(unresolved.map { ($0, RepositoryRoot.resolve($0)) }) { $1 }, checkouts, catalog)
            }.value
            self.index = updated
            codexIndex = updatedCodex
            refreshConversations()
            self.checkouts = checkouts
            catalogModels = catalog
            let listed = Set(summaries.map(\.id))
            let continued = Dictionary(summaries.compactMap { summary in summary.continuedIn.flatMap { listed.contains($0) ? (summary.id, $0) : nil } }) { first, _ in first }
            self.summaries = summaries.filter { continued[$0.id] == nil }
            for index in tabs.indices {
                guard let target = tabs[index].sessionID.flatMap({ continued[$0] }) else { continue }

                browser.rekey(from: BrowserModel.key(of: tabs[index]), to: target)
                tabs[index].sessionID = target
            }
            let pins = pinnedIDs.map { continued[$0] ?? $0 }
            if pins != pinnedIDs { pinnedIDs = pins }
            let flags = Set(flaggedIDs.map { continued[$0] ?? $0 })
            if flags != flaggedIDs { flaggedIDs = flags }
            var followed = tasks
            followed.continuing(continued)
            if followed != tasks { tasks = followed }
            repositoryRoots = roots
            for index in tabs.indices {
                guard let cwd = self.summaries.first(where: { $0.id == tabs[index].sessionID })?.cwd, cwd != tabs[index].cwd else { continue }

                tabs[index].cwd = cwd
            }
            claimNewSessions()
            if !hasScanned { hasScanned = true }
            formTasks()
            refreshLive()
            refreshPullRequestWatches()
            if searchIndexTask != nil { updateSearchIndex() }
            resolvePullRequests()
            refreshLocalClones()
            refreshEditedRepositories()
        }
    }

    func updateSearchIndex() {
        searchIndexTask = Task { [previous = searchIndexTask, refreshTask] in
            await previous?.value
            await refreshTask?.value
            let sources = await Task.detached { [index] in index.searchSources }.value
            let stale = searchIndex.stale(sources).sorted { lhs, rhs in
                let left = lhs.url.path.contains("/subagents/")
                let right = rhs.url.path.contains("/subagents/")
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
        let live = fakeLive + Harness.all.flatMap { harness -> [LiveSession] in
            guard Self.isEnabled(harness.agent) else { return [] }

            let openTabs: [LiveProbe.Tab] = harness.liveSource == .tabSignals ? tabs.compactMap { tab in
                guard tab.agent == harness.agent, let sessionID = tab.sessionID else { return nil }

                let transcript = sessionIndex(for: tab.agent).url(ofSession: sessionID)
                return LiveProbe.Tab(sessionID: sessionID, cwd: tab.cwd, terminalTitle: tab.terminal.title, opened: tab.opened, transcript: transcript)
            } : []
            return harness.readLive(LiveProbe(directory: agentDirectory(for: harness.agent), tabs: openTabs))
        }
        let byID = Dictionary(live.map { ($0.sessionId, $0) }) { first, _ in first }
        if byID != liveBySession {
            let previous = liveBySession
            liveBySession = byID
            if previous.mapValues(\.pid) != byID.mapValues(\.pid) || previous.mapValues(\.startedAt) != byID.mapValues(\.startedAt) { refreshPullRequestWatches() }
            refreshConversations()
            if groupingMode.hasActive || !snoozes.isEmpty { applyGroups() }
        }
        resumeSuspendedConversations()
        // Claude reports `shell` only while idle; a turn shows `busy`, so keep the mark until it reports plain idle.
        let shells = Set(liveBySession.values.filter { $0.activity == .shell || $0.activity != .idle && backgroundShellIDs.contains($0.sessionId) }.map(\.sessionId))
        if shells != backgroundShellIDs { backgroundShellIDs = shells }
        let processSessions = liveBySession.values.filter { $0.pid > 0 }
        let processes = Dictionary(processSessions.compactMap { session in ProcessAncestry.facts(of: session.pid).map { (session.pid, $0) } }) { first, _ in first }
        let orphans = OrphanedSessions.ids(live: processSessions, processes: processes)
        if orphans != orphanedSessionIDs { orphanedSessionIDs = orphans }
        turnStarts.update(live: liveBySession, sessions: sessionsByID)
        let claimed = Set(tabs.compactMap(\.sessionID))
        for session in live where session.pid > 0 && !claimed.contains(session.sessionId) {
            guard let position = tabs.firstIndex(where: { tab in
                tab.kind == .claude && tab.agent.harness.liveSource == .sessionFiles && tab.cwd == session.cwd && tab.sessionID.map { liveBySession[$0] == nil } ?? true
                    && session.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) >= tab.opened } ?? false
            }), ProcessAncestry.isDescendant(session.pid, of: getpid()) else { continue }

            browser.rekey(from: BrowserModel.key(of: tabs[position]), to: session.sessionId)
            tabs[position].sessionID = session.sessionId
        }
        let needsYou = NeedsYou.update(previous: waitingSessionIDs, live: Array(liveBySession.values), inBerth: Set(tabs.compactMap(\.sessionID)))
        waitingSessionIDs = needsYou.waiting
        NeedsYouAlerts.update(entered: needsYou.entered, needsYouCount: needsYou.needsYou.count, store: self)
    }

    private var unloadIdleThreshold: TimeInterval {
        UserDefaults.standard.object(forKey: GeneralSettings.unloadIdleKey) == nil ? 14_400 : UserDefaults.standard.double(forKey: GeneralSettings.unloadIdleKey)
    }

    func unloadIdleTabs() {
        refreshLive()
        let threshold = unloadIdleThreshold
        let lastClaude = recentTabIDs.first { id in tabs.contains { $0.id == id && $0.kind == .claude && $0.agent.harness.supports(.idleUnload) } }
        let candidates = tabs.filter { $0.kind == .claude && $0.agent.harness.supports(.idleUnload) && $0.id != lastClaude }.compactMap { tab in tab.sessionID.map { (id: tab.id, sessionID: $0, touched: restoredTabIDs.contains(tab.id) ? tabTouches[tab.id] ?? .distantPast : max(tab.opened, tabTouches[tab.id] ?? .distantPast)) } }
        let lastActivity = Dictionary(activeSessions.map { ($0.id, $0.lastActivity) }) { first, _ in first }
        for id in IdleTabs.unloadable(candidates, live: liveBySession, lastActivity: lastActivity, pinned: Set(pinnedIDs), selected: selectedTabID, now: .now, threshold: threshold) where tabs.first(where: { $0.id == id })?.sessionID.flatMap(pullRequestWatch(for:)) == nil { close(id) }
    }

    private var fakeLive: [LiveSession] {
        #if DEBUG
        let statuses = fakeWaiting.map { [$0 ? #""status":"waiting","waitingFor":"permission prompt","pid":1"# : #""status":"busy","pid":1"#] }
            ?? (UserDefaults.standard.bool(forKey: "snapshotFakeStatus") ? [#""status":"waiting","waitingFor":"permission prompt","pid":1"#, #""status":"busy","pid":1"#, #""status":"shell","pid":1"#] : [])
            + (UserDefaults.standard.bool(forKey: "snapshotFakeStatus") && UserDefaults.standard.bool(forKey: "snapshotRemote") ? [#""status":"idle","pid":1"#, #""status":"idle","pid":2"#] : [])
        return fakeLiveSessions + zip(groups.first { !$0.sessions.isEmpty }?.sessions ?? [], statuses).compactMap { session, status in
            let json = #"{"sessionId":"\#(session.id)","cwd":"\#(session.cwd)","startedAt":0,"statusUpdatedAt":\#(Int((Date.now.timeIntervalSince1970 - 95) * 1000)),\#(status)}"#
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

    var busySessionCount: Int {
        tabs.filter { !$0.isHosted }.compactMap(\.sessionID).count { (liveBySession[$0]?.activity ?? .idle) != .idle }
    }

    var isIdle: Bool {
        busySessionCount == 0
            && lastKeyInput.timeIntervalSinceNow < -30
            && !tabs.contains { $0.kind == .shell && !$0.isHosted && $0.title(terminalTitle: $0.terminal.title, sessionTitle: nil) == $0.terminal.title }
            && !reviewModels.values.contains(where: \.hasUnsavedEdits)
    }

    var selection: SidebarItem? {
        guard let tab = tabs.first(where: { $0.id == selectedTabID }) else { return nil }

        if let sessionID = tab.sessionID, activeSessions.contains(where: { $0.id == sessionID }) {
            return .session(sessionID)
        }
        return .tab(tab.id)
    }

    @discardableResult
    func activate(_ item: SidebarItem?, selectsTab: Bool = true) -> Bool {
        if !multiSelection.isEmpty { multiSelection = [] }

        if case let .task(id) = item, let task = sessionTasks.first(where: { $0.id == id }) {
            return activate(.session(task.sessions[0].id), selectsTab: selectsTab)
        }
        let tabID: Tab.ID
        switch item {
        case let .tab(id):
            guard tabs.contains(where: { $0.id == id }) else { return false }

            tabID = id

        case let .session(id):
            guard let session = (activeSessions + archivedSessions).first(where: { $0.id == id }) else { return false }

            if archivedAt[id] != nil { unarchive(id) }
            refreshLive()
            if let tab = tab(forSession: id), session.agent.harness.liveSource == .sessionFiles, liveBySession[id] == nil, tab.opened.timeIntervalSinceNow < -10 {
                close(tab.id)
            }
            if let tab = tab(forSession: id) {
                tabID = tab.id
            } else {
                if let live = liveBySession[id], orphanedSessionIDs.contains(id) {
                    resumeOrphan(session, live: live, selectsTab: selectsTab)
                    return true
                }
                guard !isLockedElsewhere(liveBySession[id]) else {
                    lockedSessionID = id
                    return false
                }
                guard let resumed = resume(session, selectsTab: selectsTab) else { return false }

                tabID = resumed
            }

        default: return false
        }
        guard selectsTab else { return true }

        selectedTabID = tabID
        if let parent = tabs.first(where: { $0.id == tabID })?.parentTabID { sessionPanes[parent] = .terminal }
        recentTabIDs = [tabID] + recentTabIDs.filter { $0 != tabID }
        isHarborShown = false
        focusSelected()
        return true
    }

    func isLockedElsewhere(_ live: LiveSession?) -> Bool {
        live.map { $0.pid > 0 && $0.attachID == nil && !orphanedSessionIDs.contains($0.sessionId) } ?? false
    }

    private func resumeFolder(of session: SessionSummary) -> String {
        session.originalCwd ?? (FileManager.default.fileExists(atPath: session.cwd) ? session.cwd : session.checkout)
    }

    private func end(orphan live: LiveSession) async -> Bool {
        if let facts = ProcessAncestry.facts(of: live.pid), OrphanedSessions.ids(live: [live], processes: [live.pid: facts]).contains(live.sessionId) {
            _ = await ProcessAncestry.end(live.pid)
        }
        refreshLive()
        return liveBySession[live.sessionId] == nil
    }

    private func resumeOrphan(_ session: SessionSummary, live: LiveSession, selectsTab: Bool) {
        guard resumingOrphans.insert(session.id).inserted else { return }

        Task {
            defer { resumingOrphans.remove(session.id) }

            if live.activity != .idle {
                let panel = NSAlert()
                panel.messageText = "“\(session.title)” is still running without a terminal. End it and resume here?"
                panel.addButton(withTitle: "End and Resume")
                panel.addButton(withTitle: "Cancel")
                guard panel.runModal() == .alertFirstButtonReturn else { return }
            }
            guard await end(orphan: live) else {
                lockedSessionID = session.id
                return
            }
            guard resume(session, selectsTab: selectsTab) != nil, selectsTab else { return }

            isHarborShown = false
            focusSelected()
        }
    }

    func toggleMultiSelection(_ item: SidebarItem) {
        if multiSelection.isEmpty, let current = sidebarCursor ?? selection { multiSelection = [current] }
        if multiSelection.contains(item) { multiSelection.removeAll { $0 == item } } else { multiSelection.append(item) }
        multiSelectionAnchor = item
    }

    func extendMultiSelection(to item: SidebarItem, in order: [SidebarItem]) {
        let anchor = multiSelection.isEmpty ? sidebarCursor ?? selection : multiSelectionAnchor
        guard let start = anchor.flatMap(order.firstIndex(of:)), let end = order.firstIndex(of: item) else { return toggleMultiSelection(item) }

        multiSelection = start <= end ? Array(order[start...end]) : order[end...start].reversed()
        multiSelectionAnchor = anchor
    }

    var multiSelectedTabs: [Tab] {
        selectedLast.compactMap { item in
            if case let .tab(id) = item { return tabs.first { $0.id == id } }
            guard case let .session(id) = item else { return nil }

            return tab(forSession: id)
        }
    }

    var multiSelectedSessions: [SessionSummary] {
        selectedLast.compactMap { item in
            guard case let .session(id) = item else { return nil }

            return sessionsByID[id]
        }
    }

    private var selectedLast: [SidebarItem] {
        let current = selection
        return multiSelection.filter { $0 != current } + multiSelection.filter { $0 == current }
    }

    var currentCwd: String {
        tabs.first { $0.id == selectedTabID }?.folder ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    var isConversationEnabled: Bool {
        UserDefaults.standard.bool(forKey: GeneralSettings.conversationKey)
    }

    func showsConversation(_ tab: Tab) -> Bool {
        tab.kind == .claude && tab.agent.harness.supports(.conversation) && isConversationEnabled && conversationTabIDs.contains(tab.id) && !conversationSuspended.contains(tab.id)
    }

    var selectedShowsConversation: Bool {
        tabs.first { $0.id == selectedTabID }.map(showsConversation) ?? false
    }

    var selectedConversationIsVisible: Bool {
        !isHarborShown && isConversationEnabled && selectedTabID.flatMap { conversationModels[$0] } != nil
    }

    var selectedStatusBarIsReachable: Bool {
        selectedConversationIsVisible && selectedTabID.flatMap { conversationModels[$0]?.openSubagent } == nil
    }

    var canShowConversation: Bool {
        isConversationEnabled && !isHarborShown && tabs.first { $0.id == selectedTabID }.map { $0.kind == .claude && $0.agent.harness.supports(.conversation) } == true
    }

    func setConversation(_ isShown: Bool) {
        guard let id = selectedTabID else { return }

        conversationSuspended.remove(id)
        if isShown { conversationTabIDs.insert(id) } else { conversationTabIDs.remove(id) }
        endTerminalSearch()
        DispatchQueue.main.async { [weak self] in self?.focusSelected() }
    }

    func focusSelected() {
        guard launcherMode == nil, let tab = tabs.first(where: { $0.id == selectedTabID }) else { return }

        if showsConversation(tab) { conversationFocusRequests += 1 } else { tab.terminal.requestFocus() }
    }

    func suspendConversation(_ id: Tab.ID) {
        guard conversationTabIDs.contains(id), !conversationSuspended.contains(id) else { return }

        conversationSuspended.insert(id)
        endTerminalSearch()
        DispatchQueue.main.async { [weak self] in self?.focusSelected() }
    }

    private func resumeSuspendedConversations() {
        let resumable = conversationSuspended.filter { id in tabs.first { $0.id == id }.map { ConversationFallback.canLeaveTerminal(live: $0.sessionID.flatMap { liveBySession[$0] }) } ?? true }
        guard !resumable.isEmpty else { return }

        conversationSuspended.subtract(resumable)
        DispatchQueue.main.async { [weak self] in self?.focusSelected() }
    }

    func syncConversations() {
        let shown = tabs.first { $0.id == mainTabID && !isHarborShown && showsConversation($0) }
        recentConversationModels = recentConversationModels.filter { id, recent in
            tabs.contains { $0.id == id && $0.sessionID == recent.sessionID && $0.agent == recent.agent }
        }
        for id in conversationModels.keys where id != shown?.id || recentConversationModels[id] == nil {
            conversationModels[id]?.stop()
            conversationModels[id] = nil
        }
        guard let shown, conversationModels[shown.id] == nil else { return }

        let model = recentConversationModels[shown.id]?.model ?? ConversationModel(tabID: shown.id, store: self)
        recentConversationModels[shown.id] = (model, shown.sessionID, shown.agent, .now)
        if recentConversationModels.count > 4,
           let oldest = recentConversationModels.min(by: { $0.value.shownAt < $1.value.shownAt }) {
            recentConversationModels[oldest.key] = nil
        }
        conversationModels[shown.id] = model
        model.start()
    }

    func refreshConversations() {
        for model in conversationModels.values { model.refresh() }
    }

    var focusedTerminal: TerminalViewState? {
        tabs.first { $0.id == selectedTabID }?.terminal
    }

    var terminals: [Tab] {
        tabs.filter { $0.kind == .shell && $0.parentTabID == nil }
    }

    func openShell(cwd: String, command: String? = nil, id: UUID = UUID(), parent: Tab.ID? = nil) {
        let launch = hostLaunch(command, id: id)
        tabs.append(Tab(id: id, kind: .shell, cwd: cwd, sessionID: nil, parentTabID: parent, terminal: terminal(id: id, cwd: cwd, command: launch.command) { [weak self] in self?.close(id) }, isHosted: launch.isHosted))
        selectedTabID = id
    }

    func newTerminal() {
        launcherMode = nil
        openShell(cwd: currentCwd)
        activate(selectedTabID.map(SidebarItem.tab))
    }

    func newTerminal(for parent: Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == parent && $0.kind == .claude }) else { return }

        launcherMode = nil
        openShell(cwd: tab.folder, parent: parent)
        activate(selectedTabID.map(SidebarItem.tab))
    }

    static func reviewKey(_ sessionID: String, root: String?) -> String {
        root.map { "\(sessionID)\n\($0)" } ?? sessionID
    }

    var selectedSessionID: String? {
        sessionTab?.sessionID
    }

    var mainTabID: Tab.ID? {
        let selected = tabs.first { $0.id == selectedTabID }
        return selected?.parentTabID ?? selected?.id
    }

    var sessionTab: Tab? {
        tabs.first { $0.id == mainTabID && $0.kind == .claude }
    }

    var sessionPane: SessionPane {
        sessionTab.flatMap { sessionPanes[$0.id] } ?? .changes
    }

    var isSearchingPaneTerminal: Bool {
        tabs.contains { $0.parentTabID != nil && $0.terminal === terminalSearch?.terminal }
    }

    func paneTerminal(of parent: Tab.ID) -> Tab? {
        let owned = tabs.filter { $0.parentTabID == parent }
        return owned.first { $0.id == paneTerminalIDs[parent] } ?? owned.last
    }

    func showTerminalPane() {
        guard let session = sessionTab else { return }

        launcherMode = nil
        isHarborShown = false
        if let terminal = paneTerminal(of: session.id) { activate(.tab(terminal.id)) } else { newTerminal(for: session.id) }
    }

    var shownPane: SessionPane? {
        if isHarborShown { return nil }
        if sessionPane == .terminal || sessionPane == .browser { return sessionPane }
        return UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) && showsReviewPanel ? .changes : nil
    }

    func showChangesPane() {
        showsReviewPanel = true
        isHarborShown = false
        leaveTerminalPane(of: sessionTab)
    }

    func showBrowserPane() {
        guard let session = sessionTab else { return }

        launcherMode = nil
        isHarborShown = false
        leaveTerminalPane(of: session)
        sessionPanes[session.id] = .browser
        if browser.shownTab == nil { browser.open(nil, in: BrowserModel.key(of: session)) }
    }

    func hideSessionPanel() {
        showsReviewPanel = false
        leaveTerminalPane(of: sessionTab)
    }

    private func leaveTerminalPane(of session: Tab?) {
        guard let session, sessionPanes[session.id] != nil else { return }

        sessionPanes[session.id] = nil
        guard tabs.first(where: { $0.id == selectedTabID })?.parentTabID == session.id else { return }

        selectedTabID = session.id
        focusSelected()
    }

    var primaryReviewModel: ReviewModel? {
        selectedSessionID.flatMap { reviewModels[$0] }
    }

    var reviewModel: ReviewModel? {
        guard let sessionID = selectedSessionID else { return nil }

        return activeReviewRoots[sessionID].flatMap { reviewModels[Self.reviewKey(sessionID, root: $0)] } ?? reviewModels[sessionID]
    }

    var sessionReviewModels: [ReviewModel] {
        guard let sessionID = selectedSessionID else { return [] }

        return ([reviewModels[sessionID], reviewModels[Self.reviewKey(sessionID, root: Self.sessionFilesRoot)]] + (reviewRepositories[sessionID] ?? []).map { reviewModels[Self.reviewKey(sessionID, root: $0.root)] }).compactMap(\.self)
    }

    func showPullRequestInReview(number: Int, repository: String?, repositoryPath: String? = nil, in tabID: Tab.ID) async -> Result<PullRequestLink, ReviewPullRequestFailure> {
        guard UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) else { return .failure(.init(message: "Enable Review in Settings to show a pull request")) }
        guard let caller = tabs.first(where: { $0.id == tabID }),
              let target = caller.kind == .claude ? caller : tabs.first(where: { $0.id == caller.parentTabID && $0.kind == .claude }),
              let sessionID = target.sessionID
        else { return .failure(.init(message: "Select a session tab or run berth show-pr from a session or its terminal")) }
        guard number > 0, repository.map({ PullRequestLink.validatedRepository($0) != nil }) ?? true else {
            return .failure(.init(message: "Pass a positive PR number or a GitHub pull request URL"))
        }

        let location: ReviewPullRequestLocation
        do {
            location = try await resolveReviewPullRequest(number: number, repository: repository, path: repositoryPath, caller: caller.folder, session: target.folder)
        } catch {
            return .failure(error)
        }

        let link = location.link
        let pullRequest: PullRequest? = if Snapshot.output != nil {
            Snapshot.fixtureShownPullRequests[link] ?? Snapshot.fixtureLinkedPullRequests[link]
        } else {
            await PullRequestStatus.fetch([], linked: [link]).linked[link]
        }
        guard let pullRequest else {
            return .failure(.init(message: "Couldn’t load \(link.repository) PR #\(number). Check the PR number and that gh is signed in with access to the repository"))
        }
        guard UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) else { return .failure(.init(message: "Enable Review in Settings to show a pull request")) }
        guard activate(.tab(target.id)) else { return .failure(.init(message: "The session tab closed. Open it and try again")) }

        if !showsReviewPanel { showsReviewPanel = true }
        guard let model = reviewModels[sessionID] else { return .failure(.init(message: "Review couldn’t open for this session tab")) }

        let entry = ReviewPullRequest(location: location, pullRequest: pullRequest)
        let document: ReviewDocument
        let contents: ReviewContents
        do {
            let loaded = try await model.loadPullRequestFiles(entry)
            guard let first = loaded.files.first else { return .failure(.init(message: "PR #\(number) has no changed files")) }

            document = ReviewDocument(path: first.path, compare: loaded.compare, root: location.root, pullRequestLink: link)
            contents = try await model.pullRequestContents(document)
        } catch {
            return .failure(.init(message: "Couldn’t load changed files for \(link.repository) PR #\(number). \(ReviewModel.describe(error))"))
        }
        guard UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey) else { return .failure(.init(message: "Enable Review in Settings to show a pull request")) }
        guard activate(.tab(target.id)) else { return .failure(.init(message: "The session tab closed. Open it and try again")) }

        if !showsReviewPanel { showsReviewPanel = true }
        guard reviewModels[sessionID] === model else {
            return .failure(.init(message: "The session’s Review changed while loading the PR. Try again"))
        }

        shownReviewPullRequests[sessionID, default: [:]][link] = entry
        model.expansionOverrides["otherPullRequests"] = true
        model.expandedPullRequests.insert(link)
        model.open(document, loaded: contents)
        return .success(link)
    }

    private func resolveReviewPullRequest(number: Int, repository: String?, path: String?, caller: String, session: String) async throws(ReviewPullRequestFailure) -> ReviewPullRequestLocation {
        if let path {
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw .init(message: "Pass an existing local clone folder to --repo")
            }

            let root = RepositoryRoot.resolve(path)
            guard let origin = await RepositoryRoot.gitHubRepository(at: root) else {
                throw .init(message: "Pass a local clone with a GitHub origin to --repo")
            }
            guard repository == nil || origin.lowercased() == repository?.lowercased() else {
                throw .init(message: "The --repo folder has origin \(origin). Pass a clone of \(repository ?? origin)")
            }

            return ReviewPullRequestLocation(link: PullRequestLink(repository: origin.lowercased(), number: number), root: root)
        }

        let callerRoot = RepositoryRoot.resolve(caller)
        let sessionRoot = RepositoryRoot.resolve(session)
        let roots = callerRoot == sessionRoot ? [callerRoot] : [callerRoot, sessionRoot]
        for root in roots {
            if let origin = await RepositoryRoot.gitHubRepository(at: root)?.lowercased(), repository == nil || origin == repository?.lowercased() {
                return ReviewPullRequestLocation(link: PullRequestLink(repository: origin, number: number), root: root)
            }
        }
        guard let repository = repository?.lowercased() else {
            throw .init(message: "This tab has no GitHub origin. Pass a pull request URL or use --repo <path>")
        }

        refreshLocalClones()
        await waitForLocalClones()
        let link = PullRequestLink(repository: repository, number: number)
        if let clone = localCheckout(of: repository), await RepositoryRoot.gitHubRepository(at: clone)?.lowercased() == repository {
            return ReviewPullRequestLocation(link: link, root: clone)
        }

        let siblings = await RepositoryRoot.gitHubSiblingClones(of: Set(roots))
        if let clone = siblings.values.flatMap({ $0.filter { $0.value == repository }.keys }).min() {
            return ReviewPullRequestLocation(link: link, root: clone)
        }
        throw .init(message: "No local clone of \(repository). Pass --repo <path> or clone the repository")
    }

    func sessionReviewPullRequests(of sessionID: String, changes: ReviewChanges?, excluding branchNumber: Int?) -> [ReviewPullRequest] {
        var entries = shownReviewPullRequests[sessionID] ?? [:]
        if let changes, let root = repositoryRoot(ofSession: sessionID),
           let repository = pullRequestBranch(inRoot: root, branch: changes.branch)?.repository.lowercased() {
            for pullRequest in pullRequests(inRoot: nil, of: sessionID, branch: changes.branch) where pullRequest.number != branchNumber {
                let link = PullRequestLink(repository: repository, number: pullRequest.number)
                if entries[link] == nil { entries[link] = ReviewPullRequest(location: ReviewPullRequestLocation(link: link, root: changes.root), pullRequest: pullRequest) }
            }
        }
        return entries.values.sorted { ($0.id.number, $0.id.repository) < ($1.id.number, $1.id.repository) }
    }

    func showChanges(opening paths: [String]) {
        showsReviewPanel = true
        isHarborShown = false
        prepareReviewModel()
        Task {
            for model in sessionReviewModels { await model.load() }

            for path in paths.map({ URL(filePath: $0).resolvingSymlinksInPath().path }) {
                for model in sessionReviewModels {
                    guard let root = model.changes.map({ URL(filePath: $0.root).resolvingSymlinksInPath().path }), path.hasPrefix(root + "/"), let document = model.changedDocument(at: String(path.dropFirst(root.count + 1))) else { continue }

                    model.open(document)
                    return
                }
            }
        }
    }

    func prepareReviewModel() {
        guard showsReviewPanel, UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey),
              let tab = sessionTab,
              let sessionID = tab.sessionID
        else { return }

        if let model = reviewModels[sessionID], model.folder == tab.cwd || model.hasUnsavedEdits || !model.comments.isEmpty {
            let moved = model.folder == tab.cwd ? nil : tab.cwd
            if model.movedFolder != moved { model.movedFolder = moved }
        } else {
            let model = ReviewModel(folder: tab.cwd)
            model.onOpen = { [weak self] in
                self?.activeReviewRoots[sessionID] = nil
                self?.leaveTerminalPane(of: self?.tab(forSession: sessionID))
            }
            reviewModels[sessionID] = model
        }
        prepareRepositoryModels(of: sessionID, folder: tab.cwd)
    }

    private func prepareRepositoryModels(of sessionID: String, folder: String) {
        let wanted = reviewRepositories(of: sessionID, folder: folder)
        let kept = (reviewRepositories[sessionID] ?? []).filter { repository in
            guard let model = reviewModels[Self.reviewKey(sessionID, root: repository.root)] else { return false }

            return model.hasUnsavedEdits || !model.comments.isEmpty
        }
        let shown = wanted + kept.filter { kept in !wanted.contains { $0.root == kept.root } }
        for repository in shown {
            let key = Self.reviewKey(sessionID, root: repository.root)
            if let model = reviewModels[key], model.folder == repository.folder || model.hasUnsavedEdits || !model.comments.isEmpty { continue }

            let model = ReviewModel(folder: repository.folder)
            model.onOpen = { [weak self] in
                self?.activeReviewRoots[sessionID] = repository.root
                self?.leaveTerminalPane(of: self?.tab(forSession: sessionID))
            }
            reviewModels[key] = model
            if activeReviewRoots[sessionID] == repository.root { activeReviewRoots[sessionID] = nil }
        }
        let prefix = sessionID + "\n"
        let filesKey = Self.reviewKey(sessionID, root: Self.sessionFilesRoot)
        for key in reviewModels.keys where key.hasPrefix(prefix) && key != filesKey && !shown.contains(where: { Self.reviewKey(sessionID, root: $0.root) == key }) { reviewModels[key] = nil }
        if editedFiles[sessionID]?.isEmpty ?? true {
            reviewModels[filesKey] = nil
        } else if reviewModels[filesKey] == nil {
            let model = ReviewModel()
            model.onOpen = { [weak self] in self?.activeReviewRoots[sessionID] = Self.sessionFilesRoot }
            reviewModels[filesKey] = model
        }
        if reviewRepositories[sessionID] ?? [] != shown { reviewRepositories[sessionID] = shown }
    }

    private func reviewRepositories(of sessionID: String, folder: String) -> [ReviewRepository] {
        let own = sessionsByID[sessionID].flatMap { repositoryRoots[$0.checkout] } ?? RepositoryRoot.resolve(folder)
        let members = task(containing: sessionID)?.sessionIDs.compactMap { sessionsByID[$0] }.sorted { $0.lastPrompt > $1.lastPrompt } ?? []
        let tasked = members.compactMap { member -> ReviewRepository? in
            guard member.id != sessionID, let root = repositoryRoots[member.checkout], FileManager.default.fileExists(atPath: member.cwd) else { return nil }

            return ReviewRepository(root: root, folder: member.cwd, isEdited: false)
        }
        let edited = (editedRepositories[sessionID] ?? [:]).sorted { $0.key < $1.key }.map { ReviewRepository(root: $0.key, folder: $0.value, isEdited: true) }
        var seen: Set<String> = [own]
        return (tasked + edited).filter { seen.insert($0.root).inserted }
    }

    func refreshReview() async {
        refresh()
        await waitForScan()
        prepareReviewModel()
        for model in sessionReviewModels { await model.load() }
    }

    func pullRequests(inRoot root: String?, of sessionID: String, branch: String?) -> [PullRequest] {
        let own = root ?? sessionsByID[sessionID].flatMap { repositoryRoots[$0.checkout] }
        let repository = own.flatMap { repositories[$0] ?? nil }
        let task = task(containing: sessionID)
        let sessions = (task?.sessionIDs ?? [sessionID]).compactMap { sessionsByID[$0] }.filter { $0.id == sessionID || repositoryRoots[$0.checkout] == own }
        let fromSessions = sessions.flatMap { currentPullRequests(of: $0, in: task) }.filter { $0.repository.lowercased() == repository?.lowercased() }.map(\.pullRequest)
        let fromBranch = repository.flatMap { repository in branch.flatMap { pullRequests[PullRequestBranch(repository: repository, branch: $0)] ?? nil } }
        var seen: Set<Int> = []
        return (fromSessions + [fromBranch].compactMap(\.self)).filter { seen.insert($0.number).inserted }.sorted { $0.number < $1.number }
    }

    func pullRequestBranch(inRoot root: String, branch: String) -> PullRequestBranch? {
        (repositories[root] ?? nil).map { PullRequestBranch(repository: $0, branch: branch) }
    }

    func refreshEditedRepositories() {
        guard showsReviewPanel, UserDefaults.standard.bool(forKey: GeneralSettings.reviewKey), let sessionID = selectedSessionID, let url = index.url(ofSession: sessionID) else { return }

        editedTask = Task { [previous = editedTask] in
            await previous?.value
            let cached = editedTranscripts[sessionID].flatMap { $0.url == url ? $0.edits : nil } ?? TranscriptEdits()
            let (edits, files) = await Task.detached {
                var edits = cached
                edits.read(url)
                return (edits, edits.existingFiles)
            }.value
            let open = Set(tabs.compactMap(\.sessionID))
            editedTranscripts = editedTranscripts.filter { open.contains($0.key) }.merging([sessionID: (url, edits)]) { $1 }
            guard editedRepositories[sessionID] ?? [:] != edits.repositories || editedFiles[sessionID] ?? [] != files else { return }

            editedRepositories[sessionID] = edits.repositories
            editedFiles[sessionID] = files
            prepareReviewModel()
            resolvePullRequests()
        }
    }

    func watchReview(_ roots: [String]) async {
        reviewWatchers = []
        reviewReload?.cancel()
        reviewIgnored = [:]
        var watchers: [FileWatcher] = []
        for root in roots {
            guard let location = try? await ReviewGit.gitDirectories(in: root) else { continue }

            reviewIgnored[root] = await (try? ReviewGit.ignoredDirectories(in: root)) ?? []
            let watched = [location.directory + "/HEAD", location.directory + "/index", location.common + "/packed-refs"]
            watchers.append(FileWatcher(paths: [root, location.common], latency: 0.5) { [weak self] paths in
                guard let self else { return }

                let isRelevant = paths.contains { path in
                    path.hasPrefix(location.common + "/") || path.hasPrefix(location.directory + "/")
                        ? watched.contains(path) || path.hasPrefix(location.common + "/refs/") && !path.hasSuffix(".lock")
                        : !(reviewIgnored[root] ?? []).contains(where: (path + "/").hasPrefix)
                }
                guard isRelevant else { return }

                reviewReload?.cancel()
                reviewReload = Task {
                    guard await (try? Task.sleep(for: .milliseconds(500))) != nil else { return }

                    reviewIgnored[root] = await (try? ReviewGit.ignoredDirectories(in: root)) ?? reviewIgnored[root]
                    await refreshReview()
                }
            })
        }
        guard !Task.isCancelled else { return }

        reviewWatchers = watchers
    }

    func watchForRepository(in folder: String?) {
        repositoryWatcher = nil
        guard let folder else { return }

        let dotGit = URL(filePath: folder).resolvingSymlinksInPath().appending(path: ".git").path
        repositoryWatcher = FileWatcher(paths: [folder], latency: 0.5) { [weak self] paths in
            guard paths.contains(where: { $0.hasSuffix("/.git") && URL(filePath: $0).resolvingSymlinksInPath().path == dotGit }) else { return }

            Task { await self?.refreshReview() }
        }
    }

    func closeDiff(tab id: ReviewTab.ID? = nil) {
        guard let model = reviewModel else { return }

        if id == nil, model.isPreviewSelected {
            model.closePreview()
            return
        }
        guard let id = id ?? model.selectedTabID else { return }

        let isSelected = id == model.selectedTabID
        model.close(id)
        if model.tabs.isEmpty, let sessionID = selectedSessionID { activeReviewRoots[sessionID] = nil }
        if model.tabs.isEmpty { focusSelected() } else if isSelected { model.focusesEditor = true }
    }

    func startTerminalSearch(in terminal: TerminalViewState, needle: String?) {
        guard focusedTerminal === terminal else { return }

        if terminalSearch?.terminal !== terminal { terminalSearch = TerminalSearch(terminal: terminal) }
        if let needle { terminalSearch?.needle = needle }
        terminalSearch?.focusRequests += 1
    }

    func endTerminalSearch() {
        terminalSearch?.terminal.performBindingAction("end_search")
        terminalSearch = nil
    }

    func switchTerminal() {
        launcherMode = nil
        if !isHarborShown, let session = sessionTab {
            if sessionPanes[session.id] == .terminal {
                sessionPanes[session.id] = nil
                activate(.tab(session.id))
            } else {
                showTerminalPane()
            }
            return
        }

        let kind: Tab.Kind = !isHarborShown && tabs.first { $0.id == selectedTabID }?.kind == .shell ? .claude : .shell
        let recent = recentTabIDs.lazy.compactMap { id in self.tabs.first { $0.id == id && $0.kind == kind } }.first
        if let target = recent ?? tabs.last(where: { $0.kind == kind }) {
            activate(.tab(target.id))
            return
        }
        if kind == .shell { newTerminal() }
    }

    var showsActive: Bool { groupingMode.hasActive && !showsTriage }

    var activeLiveIDs: Set<String> { showsActive ? Set(liveSessions.map(\.id)) : [] }

    var sidebarActive: (group: SessionGroup, tabs: [Tab], entries: [GroupEntry])? {
        guard showsActive else { return nil }

        let starting = unlistedClaudeTabs
        guard !liveSessions.isEmpty || !starting.isEmpty else { return nil }

        return (SessionGroup(kind: .active, sessions: liveSessions), starting, SessionTask.activeEntries(of: liveSessions, tasks: sessionTasks))
    }

    private var unlistedClaudeTabs: [Tab] {
        let listed = Set(activeSessions.map(\.id))
        return tabs.filter { $0.kind == .claude && !($0.sessionID.map(listed.contains) ?? false) }
    }

    var sidebarGroups: [(group: SessionGroup, tabs: [Tab], entries: [GroupEntry])] {
        let liveIDs = activeLiveIDs
        let unlisted = showsActive ? [] : unlistedClaudeTabs
        let grouping = grouping
        let placed = Dictionary(grouping: unlisted) { SessionGroup(kind: grouping.kind(forFolder: $0.cwd, lastPrompt: $0.opened), sessions: []).id }
        let known = Set(groups.map(\.id))
        let extra = Array(Set(unlisted.map { grouping.kind(forFolder: $0.cwd, lastPrompt: $0.opened) }))
            .map { SessionGroup(kind: $0, sessions: []) }
            .filter { !known.contains($0.id) }
            .sorted { $0.id < $1.id }
        return SessionGrouping.place(groups.filter { $0.custom != nil }, among: extra + groups.filter { $0.custom == nil })
            .map { group in (group, placed[group.id] ?? [], SessionTask.entries(of: group.sessions, tasks: sessionTasks, liveIDs: liveIDs)) }
            .filter { $0.0.custom != nil || !$0.1.isEmpty || !$0.2.isEmpty }
    }

    var sidebarOrderedTabs: [Tab] {
        let liveIDs = activeLiveIDs
        let attentionIDs = attentionSessions.map(\.id)
        let triage = triageSections
        let triageIDs = triage.working.map(\.id) + triage.unread.map(\.id)
        let attention = Set(attentionIDs + triageIDs)
        let tabs = { (entries: [GroupEntry]) -> [Tab] in
            entries.flatMap { entry in
                switch entry {
                case let .session(id): [id]
                case let .task(id): self.sessionTasks.first { $0.id == id }?.sessions.map(\.id) ?? []
                }
            }.filter { !attention.contains($0) }.compactMap { self.tab(forSession: $0) }
        }
        let active = sidebarActive
        let ordered = terminals + attentionIDs.compactMap { tab(forSession: $0) } + (active?.tabs ?? []) + tabs(active?.entries ?? [])
            + triageIDs.compactMap { tab(forSession: $0) }
            + pinnedSessions.filter { !liveIDs.contains($0.id) && !attention.contains($0.id) }.compactMap { tab(forSession: $0.id) }
            + sidebarGroups.flatMap { $0.tabs + tabs($0.entries) }
        return ordered.flatMap { owner in [owner] + self.tabs.filter { $0.parentTabID == owner.id } }
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

    @discardableResult
    func openSession(_ agent: Agent = Store.defaultAgent, cwd: String, resuming sessionID: String? = nil, checkout: NewSessionCheckout = .preferred, pasting prompt: String? = nil, selectsTab: Bool = true) -> Tab.ID? {
        let harness = agent.harness
        let session = sessionID ?? (harness.claimsNewSession ? nil : UUID().uuidString.lowercased())
        let attachID = session.flatMap { liveBySession[$0]?.attachID }
        let start: LaunchStart = if attachID != nil {
            .attach
        } else if sessionID != nil {
            .resume
        } else if harness.supports(.worktrees), checkout == .worktree || checkout == .preferred && UserDefaults.standard.bool(forKey: GeneralSettings.worktreeKey), FileManager.default.fileExists(atPath: URL(filePath: RepositoryRoot.resolve(cwd)).appending(path: ".git").path) {
            .newInWorktree
        } else {
            .new
        }
        let id = UUID()
        #if DEBUG
        if opensAreProbed {
            probeOpened.append((agent, cwd, start, prompt))
            return id
        }
        #endif
        guard FileManager.default.fileExists(atPath: cwd) else {
            missingFolder = cwd
            return nil
        }

        let environment = session.map { [ClaudeLaunch.sessionVariable: attachID ?? $0] } ?? [:]
        let options = LaunchOptions(
            model: UserDefaults.standard.string(forKey: "launchModel.\(agent.rawValue)"),
            effort: UserDefaults.standard.string(forKey: "launchEffort.\(agent.rawValue)")
        )
        let launch = hostLaunch(harness.command(start, options), id: id)
        tabs.append(Tab(id: id, kind: .claude, cwd: cwd, sessionID: session, agent: agent, terminal: terminal(id: id, cwd: cwd, command: launch.command, environment: environment) { [weak self] in self?.close(id) }, isHosted: launch.isHosted))
        if isConversationEnabled, harness.supports(.conversation), UserDefaults.standard.string(forKey: GeneralSettings.conversationViewKey) == "conversation" { conversationTabIDs.insert(id) }
        if selectsTab {
            selectedTabID = id
            recentTabIDs = [id] + recentTabIDs.filter { $0 != id }
        }
        if let prompt, let session { Task { await paste(prompt, intoStartingSession: session, tab: id) } }
        return id
    }

    @discardableResult
    private func resume(_ session: SessionSummary, selectsTab: Bool = true) -> Tab.ID? {
        let folder = resumeFolder(of: session)
        return openSession(session.agent, cwd: folder, resuming: session.id, selectsTab: selectsTab)
    }

    private func claimNewSessions() {
        var claimed = Set(tabs.compactMap(\.sessionID))
        for index in tabs.indices where tabs[index].sessionID == nil {
            guard let claim = tabs[index].agent.harness.claim, let session = claim(tabs[index].opened, tabs[index].cwd, summaries, claimed) else { continue }

            browser.rekey(from: BrowserModel.key(of: tabs[index]), to: session.id)
            tabs[index].sessionID = session.id
            claimed.insert(session.id)
        }
    }

    var isCodexEnabled: Bool {
        Self.isEnabled(.codex)
    }

    static func isEnabled(_ agent: Agent) -> Bool {
        let key = "\(agent.rawValue)Enabled"
        return UserDefaults.standard.object(forKey: key) == nil ? !agent.harness.isOptIn : UserDefaults.standard.bool(forKey: key)
    }

    static var defaultAgent: Agent {
        let enabled = Agent.allCases.filter(isEnabled)
        let chosen = UserDefaults.standard.string(forKey: GeneralSettings.defaultAgentKey).flatMap(Agent.init(rawValue:))
        return chosen.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first ?? .claude
    }

    static var otherAgent: Agent? {
        Agent.allCases.first { $0 != defaultAgent && isEnabled($0) }
    }

    func applyCodexSetting() {
        let paths = ["sessions", "session_index.jsonl"].map { Self.codexDirectory.appending(path: $0).path }
        codexWatcher = isCodexEnabled ? FileWatcher(paths: paths, latency: 1) { [weak self] _ in
            self?.refresh()
            Task { await self?.refreshCodexUsage() }
        } : nil
        refresh()
        Task { await refreshCodexUsage() }
    }

    private func paste(_ prompt: String, intoStartingSession sessionID: String, tab id: Tab.ID) async {
        let deadline = Date.now + 120
        while liveBySession[sessionID].map({ $0.status == "waiting" }) ?? true {
            guard Date.now < deadline, tabs.contains(where: { $0.id == id }), await (try? Task.sleep(for: .milliseconds(250))) != nil else { return }

            refreshLive()
        }
        let tabAge = tabs.first { $0.id == id }.map { Date.now.timeIntervalSince($0.opened) } ?? 0
        try? await Task.sleep(for: .seconds(max(2, 5 - tabAge)))
        refreshLive()
        guard let terminal = tabs.first(where: { $0.id == id })?.terminal, liveBySession[sessionID].map({ $0.status != "waiting" }) == true else { return }

        if let clear = TerminalKeyPress(typing: "u", modifiers: .ctrl) {
            terminal.sendKey(clear)
            try? await Task.sleep(for: .milliseconds(200))
        }
        refreshLive()
        guard tabs.contains(where: { $0.id == id && $0.sessionID == sessionID }),
              liveBySession[sessionID].map({ $0.status != "waiting" }) == true, terminal.paste(text: prompt)
        else { return }

        if selectedTabID == id, launcherMode == nil { terminal.requestFocus() }
    }

    private func terminal(id: UUID, cwd: String, command: String?, environment: [String: String] = [:], onClose: @escaping () -> Void) -> TerminalViewState {
        let terminal = TerminalViewState(controller: GhosttyConfig.controller)
        terminal.makePlatformView = { VisibleDropTerminalView(frame: .zero) }
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: cwd,
            envVars: environment.merging(control.environment(for: id)) { current, _ in current },
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

        let current = Set(sidebarGroups.map(\.group.id) + [Sidebar.terminalsID, Sidebar.attentionID, Sidebar.workingID, Sidebar.unreadID] + (sidebarActive.map { [$0.group.id] } ?? []))
        let others = (UserDefaults.standard.string(forKey: "collapsedGroups") ?? "").split(separator: "\n").map(String.init).filter { !current.contains($0) }
        let listed = current.filter { Sidebar.collapsedByDefault.contains($0) == expanded }.sorted()
        UserDefaults.standard.set((others + listed).joined(separator: "\n"), forKey: "collapsedGroups")
    }

    func archive(_ sessionID: String) {
        archivedAt[sessionID] = .now
        snoozes[sessionID] = nil
        pinnedIDs.removeAll { $0 == sessionID }
        if multiSelection.contains(.session(sessionID)) { multiSelection.removeAll { $0 == .session(sessionID) } }
        applyGroups()
        if let tab = tab(forSession: sessionID) { close(tab.id) }
        browser.discard(sessionID)
    }

    func dismissAttention(_ sessionID: String) {
        dismissedFailures[sessionID] = sessionsByID[sessionID].flatMap { pullRequest(for: $0)?.headSHA }
    }

    func unarchive(_ sessionID: String) {
        archivedAt[sessionID] = nil
        applyGroups()
    }

    func snooze(_ sessionID: String, _ snooze: SessionSnooze) {
        snoozes[sessionID] = snooze
        pinnedIDs.removeAll { $0 == sessionID }
        multiSelection.removeAll { $0 == .session(sessionID) }
        applyGroups()
    }

    func unsnooze(_ sessionID: String) {
        snoozes[sessionID] = nil
        applyGroups()
    }

    func snooze(of sessionID: String) -> SessionSnooze? {
        snoozes[sessionID]
    }

    private func scheduleSnoozeWake() {
        snoozeWake?.cancel()
        let due = snoozes.values.compactMap { snooze -> Date? in if case let .until(date) = snooze { date } else { nil } }.min()
        guard let due else { return }

        snoozeWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(due.timeIntervalSinceNow, 0) + 0.5))
            guard !Task.isCancelled else { return }

            self?.applyGroups()
        }
    }

    func hasUnseenActivity(_ session: SessionSummary) -> Bool {
        guard let seen = seenAt[session.id] else { return false }

        return session.lastActivity > seen
    }

    func isUnread(_ session: SessionSummary) -> Bool {
        guard hasUnseenActivity(session) else { return false }

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
        for terminal in tabs.filter({ $0.parentTabID == id }) { close(terminal.id) }
        let parent = tabs.first { $0.id == id }?.parentTabID
        let processes = ProcessAncestry.descendants()
        let sessionID = tabs.first { $0.id == id }?.sessionID
        if !isTerminating, tabs.first(where: { $0.id == id })?.isHosted == true { hangUpHost(of: id) }
        if let pid = sessionID.flatMap({ liveBySession[$0]?.pid }), pid > 0, ProcessAncestry.isDescendant(pid, of: getpid()) {
            for signal in [SIGHUP, SIGTERM] { kill(pid, signal) }
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            ProcessAncestry.hangUpOrphans(of: processes)
            try? await Task.sleep(for: .seconds(1))
            refreshLive()
        }
        if let sessionID {
            reviewModels = reviewModels.filter { $0.key != sessionID && !$0.key.hasPrefix(sessionID + "\n") }
            activeReviewRoots[sessionID] = nil
            shownReviewPullRequests[sessionID] = nil
            reviewRepositories[sessionID] = nil
            editedRepositories[sessionID] = nil
            editedFiles[sessionID] = nil
        }
        conversationTabIDs.remove(id)
        conversationSuspended.remove(id)
        conversationDrafts[id] = nil
        if let closing = tabs.first(where: { $0.id == id && $0.kind == .claude }) { browser.release(BrowserModel.key(of: closing)) }
        sessionPanes[id] = nil
        paneTerminalIDs[id] = nil
        tabs.removeAll { $0.id == id }
        if let parent, sessionPanes[parent] == .terminal, !tabs.contains(where: { $0.parentTabID == parent }) { sessionPanes[parent] = nil }
        pullRequestTabs = pullRequestTabs.filter { $0.value != id }
        recentTabIDs.removeAll { $0 == id }
        if multiSelection.contains(.tab(id)) { multiSelection.removeAll { $0 == .tab(id) } }
        guard selectedTabID == id else { return }

        let sibling = parent.flatMap { owner in recentTabIDs.first { recent in tabs.contains { $0.id == recent && $0.parentTabID == owner } } }
        selectedTabID = sibling ?? parent ?? recentTabIDs.first ?? tabs.last?.id
        guard !isHarborShown else { return }

        focusSelected()
    }

    private struct SavedTab: Codable {
        let id: UUID?
        let kind: Tab.Kind
        let cwd: String
        let sessionID: String?
        let isSelected: Bool?
        let agent: Agent?
        let parentID: Tab.ID?
    }

    func saveOpenTabs() {
        guard persistsTabs else { return }

        let saved = tabs.map { SavedTab(id: $0.id, kind: $0.kind, cwd: $0.folder, sessionID: $0.sessionID, isSelected: $0.id == selectedTabID, agent: $0.agent, parentID: $0.parentTabID) }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "openTabs")
    }

    func reattach(id: UUID, kind: Tab.Kind, cwd: String, sessionID: String?, agent: Agent = .claude, parent: Tab.ID? = nil) {
        guard let command = attachCommand(of: id) else { return }

        let environment = sessionID.map { [ClaudeLaunch.sessionVariable: $0] } ?? [:]
        tabs.append(Tab(id: id, kind: kind, cwd: cwd, sessionID: sessionID, agent: agent, parentTabID: parent, terminal: terminal(id: id, cwd: cwd, command: command, environment: environment) { [weak self] in self?.close(id) }, isHosted: true))
        selectedTabID = id
        recentTabIDs = [id] + recentTabIDs.filter { $0 != id }
        if kind == .claude { restoredTabIDs.insert(id) }
    }

    private func restoreOpenTabs() async {
        guard let data = UserDefaults.standard.data(forKey: "openTabs"),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: data)
        else { return }

        let threshold = unloadIdleThreshold
        var selected: Tab.ID?
        var restored: [Tab.ID: Tab.ID] = [:]
        for tab in saved {
            let parent = tab.parentID.flatMap { restored[$0] }.flatMap { id in tabs.contains { $0.id == id && $0.kind == .claude } ? id : nil }
            if let id = tab.id, let socket = hostSocket(of: id), SessionHost.probe(socketPath: socket) != nil {
                reattach(id: id, kind: tab.kind, cwd: tab.cwd, sessionID: tab.sessionID, agent: tab.agent ?? .claude, parent: parent)
                if tabs.contains(where: { $0.id == id }) { restored[id] = id }
                if tab.isSelected == true { selected = id }
                continue
            }
            if tab.kind == .shell {
                openShell(cwd: tab.cwd, parent: parent)
            } else {
                guard let session = activeSessions.first(where: { $0.id == tab.sessionID && $0.agent == (tab.agent ?? .claude) }), !isLockedElsewhere(liveBySession[session.id]) else { continue }

                let folder = resumeFolder(of: session)
                guard FileManager.default.fileExists(atPath: folder) else { continue }

                if let live = liveBySession[session.id], orphanedSessionIDs.contains(session.id) {
                    guard live.activity == .idle, await end(orphan: live) else { continue }
                }

                let isStale = threshold > 0 && tab.isSelected != true && !pinnedIDs.contains(session.id) && Date.now.timeIntervalSince(session.lastActivity) > threshold
                guard !isStale else { continue }

                resume(session)
                if let id = selectedTabID { restoredTabIDs.insert(id) }
            }
            if let id = tab.id { restored[id] = selectedTabID }
            if tab.isSelected == true { selected = selectedTabID }
        }
        let parents = Dictionary(uniqueKeysWithValues: saved.compactMap { tab -> (Tab.ID, Tab.ID)? in
            guard let id = tab.id.flatMap({ restored[$0] }), let parent = tab.parentID.flatMap({ restored[$0] }),
                  tabs.contains(where: { $0.id == parent && $0.kind == .claude }) else { return nil }

            return (id, parent)
        })
        tabs = tabs.map { tab in
            var tab = tab
            if tab.kind == .shell { tab.parentTabID = parents[tab.id] }
            return tab
        }
        activate((selected ?? tabs.first { $0.kind == .claude }?.id ?? tabs.first?.id).map(SidebarItem.tab))
        for id in restoredTabIDs { tabTouches[id] = nil }
    }
}
