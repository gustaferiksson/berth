import AppKit
import BerthCore
import GhosttyTerminal
import SwiftUI

enum Snapshot {
    #if DEBUG
    static let output = UserDefaults.standard.string(forKey: "snapshot").map { URL(filePath: $0) }
    #else
    static let output: URL? = nil
    #endif

    #if DEBUG
    static let scrollsToArchive = UserDefaults.standard.integer(forKey: "snapshotArchiveRow") > 0
    #else
    static let scrollsToArchive = false
    #endif

    #if DEBUG
    static let sidebarWidth = UserDefaults.standard.object(forKey: "snapshotSidebarWidth") == nil ? 300 : UserDefaults.standard.double(forKey: "snapshotSidebarWidth")
    #else
    static let sidebarWidth = 300.0
    #endif

    #if DEBUG
    private static let longNames: [(session: SessionSummary, pullRequest: PullRequest?)] = {
        let code = NSTemporaryDirectory() + "berth-long-names"
        let billing = "\(code)/acme-platform-billing-reconciliation-pipeline-service"
        let onboarding = "\(code)/northwind-customer-onboarding-document-verification-worker"
        let legacy = "\(code)/acme-platform-billing-reconciliation-pipeline-service-legacy-adapter"
        for folder in [billing, onboarding, legacy, "\(code)/api"] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        return [
            (SessionSummary(id: "fixture-1", cwd: billing, title: "Reconcile ledger entries against settlement exports and flag every mismatch", lastActivity: .now - 120, branch: "feature/reconcile-settlement-exports-with-ledger-entries"), PullRequest(number: 4821, url: URL(string: "https://github.com/acme/billing/pull/4821")!, title: "Reconcile ledger entries", state: .open)),
            (SessionSummary(id: "fixture-2", cwd: billing, title: "Fix rounding", lastActivity: .now - 900, branch: "fix/rounding"), PullRequest(number: 4790, url: URL(string: "https://github.com/acme/billing/pull/4790")!, title: "Fix rounding", state: .merged)),
            (SessionSummary(id: "fixture-3", cwd: onboarding, title: "Retry document verification when the upstream provider times out", lastActivity: .now - 2400, branch: "chore/upgrade-document-verification-provider-sdk-to-latest-major"), nil),
            (SessionSummary(id: "fixture-4", cwd: "\(code)/api", title: "Draft the webhook signature check", lastActivity: .now - 3000, branch: "feature/webhook-signature-verification-with-rotating-secrets"), PullRequest(number: 12, url: URL(string: "https://github.com/acme/billing/pull/12")!, title: "Webhook signatures", state: .draft)),
            (SessionSummary(id: "fixture-5", cwd: onboarding, title: "Explain the onboarding state machine", lastActivity: .now - 4000), nil),
            (SessionSummary(id: "fixture-6", cwd: legacy, title: "Port the nightly settlement import", lastActivity: .now - 90_000, branch: "main"), PullRequest(number: 99_999, url: URL(string: "https://github.com/acme/billing/pull/99999")!, title: "Port the nightly import", state: .closed)),
        ]
    }()

    private static let reviewPullRequest: [(session: SessionSummary, pullRequest: PullRequest?)] = {
        guard let folder = UserDefaults.standard.string(forKey: "snapshotReview"), let branch = UserDefaults.standard.string(forKey: "snapshotReviewPullRequest") else { return [] }

        let session = SessionSummary(id: "snapshot-review", cwd: folder, title: "Review fixture", lastActivity: .now, branch: branch)
        let state = UserDefaults.standard.string(forKey: "snapshotReviewPullRequestState") ?? "Open"
        return [(session, PullRequestState(rawValue: state.capitalized).map { PullRequest(number: 4821, url: URL(string: "https://github.com/acme/billing/pull/4821")!, title: "Reconcile ledger entries against settlement exports and flag every mismatch", state: $0, baseRefName: UserDefaults.standard.string(forKey: "snapshotReviewPullRequestBase")) })]
    }()

    static let fixturePullRequestDetail: PullRequestDetail? = {
        let counts = (UserDefaults.standard.string(forKey: "snapshotReviewChecks") ?? "").split(separator: ":").compactMap { Int($0) }
        guard counts.count == 4 else { return nil }

        let state = counts[1] > 0 ? "FAILURE" : counts[2] > 0 ? "PENDING" : "SUCCESS"
        let threads = Array(repeating: #"{"isResolved":false}"#, count: counts[3]) + [#"{"isResolved":true}"#]
        let response = #"{"data":{"repository":{"pullRequest":{"statusCheckRollup":{"state":"\#(state)","contexts":{"checkRunCountsByState":[{"state":"SUCCESS","count":\#(counts[0])},{"state":"FAILURE","count":\#(counts[1])},{"state":"IN_PROGRESS","count":\#(counts[2])}]}},"reviewThreads":{"nodes":[\#(threads.joined(separator: ","))]}}}}}"#
        return PullRequestDetail.parse(Data(response.utf8))
    }()

    private static let pullRequestFixtures = UserDefaults.standard.bool(forKey: "snapshotLongNames") ? longNames : reviewPullRequest

    static let launcherKeys = UserDefaults.standard.string(forKey: "snapshotLauncherKeys")

    private static let hubFolders: [SessionSummary] = {
        let code = NSTemporaryDirectory() + "berth-launcher-keys"
        for name in ["x-hub-ui/.git", "x-hub"] { try? FileManager.default.createDirectory(atPath: "\(code)/\(name)", withIntermediateDirectories: true) }
        return [
            SessionSummary(id: "fixture-hub-ui", cwd: "\(code)/x-hub-ui", title: "Fixture UI", lastActivity: .now - 420),
            SessionSummary(id: "fixture-hub", cwd: "\(code)/x-hub", title: "Fixture API", lastActivity: .now - 72_000),
        ]
    }()

    private static let inboxFixtures: (sessions: [SessionSummary], repositories: [String: String?], pullRequests: [PullRequestBranch: PullRequest?], inbox: [InboxPullRequest]?)? = {
        guard UserDefaults.standard.string(forKey: "snapshotPullRequests") != nil else { return nil }

        let code = NSTemporaryDirectory() + "berth-pull-requests"
        for name in ["billing/.git", "web/.git"] { try? FileManager.default.createDirectory(atPath: "\(code)/\(name)", withIntermediateDirectories: true) }
        let billing = "\(code)/billing"
        let web = "\(code)/web"
        let node = { (number: Int, repository: String, title: String, branch: String, author: String, hours: Double, draft: Bool, checks: String, decision: String) in
            let rollup = checks.isEmpty ? "null" : #"{"state":"\#(checks)"}"#
            let reviewDecision = decision.isEmpty ? "null" : #""\#(decision)""#
            return #"{"number":\#(number),"title":"\#(title)","url":"https://github.com/\#(repository)/pull/\#(number)","isDraft":\#(draft),"updatedAt":"\#((Date.now - hours * 3600).ISO8601Format())","headRefName":"\#(branch)","reviewDecision":\#(reviewDecision),"author":{"login":"\#(author)"},"repository":{"nameWithOwner":"\#(repository)"},"statusCheckRollup":\#(rollup)}"#
        }
        let reviewRequested = [
            node(88, "acme/web", "Add usage export page", "lee/usage-export-page", "lee", 3, false, "SUCCESS", "REVIEW_REQUIRED"),
            node(415, "northwind/infra", "Rotate the state bucket key", "sam/rotate-key", "sam", 26, false, "PENDING", ""),
        ]
        let mine = [
            node(212, "acme/billing", "Fix rounding in invoice totals", "fix/invoice-rounding", "me", 0.01, false, "FAILURE", "CHANGES_REQUESTED"),
            node(214, "acme/billing", "Usage export API", "feat/usage-export-api", "me", 2, false, "SUCCESS", "APPROVED"),
            node(89, "acme/web", "Usage export in dashboard", "feat/usage-dashboard", "me", 1, true, "PENDING", ""),
            node(150, "acme/billing", "Drop the legacy CSV importer", "chore/drop-csv-importer", "me", 1080, false, "SUCCESS", ""),
        ]
        let assigned = [node(77, "acme/web", "Fix the flaky login test", "kim/flaky-login", "kim", 120, false, "", "")]
        let json = #"{"data":{"reviewRequested":{"nodes":[\#(reviewRequested.joined(separator: ","))]},"mine":{"nodes":[\#(mine.joined(separator: ","))]},"assigned":{"nodes":[\#(assigned.joined(separator: ","))]}}}"#
        return (
            [
                SessionSummary(id: "fixture-rounding", cwd: billing, title: "Fix rounding in invoice totals", lastActivity: .now - 60, branch: "fix/invoice-rounding"),
                SessionSummary(id: "fixture-usage", cwd: billing, title: "Usage export API and dashboard", lastActivity: .now - 3600, branch: "main", pullRequests: [PullRequestLink(repository: "acme/web", number: 89), PullRequestLink(repository: "acme/billing", number: 214)]),
                SessionSummary(id: "fixture-web", cwd: web, title: "Tidy the web build", lastActivity: .now - 86_400, branch: "main"),
            ],
            [RepositoryRoot.resolve(billing): "acme/billing", RepositoryRoot.resolve(web): "acme/web"],
            [
                PullRequestBranch(repository: "acme/billing", branch: "fix/invoice-rounding"): PullRequest(number: 212, url: URL(string: "https://github.com/acme/billing/pull/212")!, title: "Fix rounding in invoice totals", state: .open, checks: .failed),
                PullRequestBranch(repository: "acme/billing", branch: "main"): PullRequest?.none,
                PullRequestBranch(repository: "acme/web", branch: "main"): PullRequest?.none,
            ],
            PullRequestInbox.parse(Data(json.utf8))
        )
    }()

    private static let taskFixtures: (sessions: [SessionSummary], repositories: [String: String?], pullRequests: [PullRequestBranch: PullRequest?], tasks: TaskState)? = {
        let reviewing = UserDefaults.standard.bool(forKey: "snapshotTasksReview")
        guard UserDefaults.standard.bool(forKey: "snapshotTasks") || reviewing else { return nil }

        let code = reviewing ? tasksReviewFolder : NSTemporaryDirectory() + "berth-tasks"
        if !reviewing { for name in ["billing/.git", "web/.git", "infra/.git"] { try? FileManager.default.createDirectory(atPath: "\(code)/\(name)", withIntermediateDirectories: true) } }
        let usage = IssueRef(repository: "acme/billing", number: 57)
        let rounding = IssueRef(repository: "acme/billing", number: 58)
        let cleanup = (212...217).map { PullRequestLink(repository: "acme/billing", number: $0) }
        let sessions = [
            SessionSummary(id: "task-usage-api", cwd: "\(code)/billing", title: "Add the usage export CSV endpoint", lastActivity: .now - 300, branch: "usage-export", issueRefs: [usage]),
            SessionSummary(id: "task-usage-web", cwd: "\(code)/web", title: "Add the usage export button to the dashboard", lastActivity: .now - 1200, branch: "feat/export-button", issueRefs: [usage]),
            SessionSummary(id: "task-rounding", cwd: "\(code)/billing", title: "Fix rounding in invoice totals", lastActivity: .now - 2400, branch: "fix/invoice-rounding", pullRequests: [cleanup[0]]),
            SessionSummary(id: "task-rounding-web", cwd: "\(code)/web", title: "Show rounded totals on the invoice page", lastActivity: .now - 3600, branch: "feat/rounded-totals", pullRequests: [cleanup[0]]),
            SessionSummary(id: "task-sweep", cwd: "\(code)/billing", title: "Close out the stale pull requests", lastActivity: .now - 4800, branch: "chore/cleanup", pullRequests: cleanup, issueRefs: [usage]),
            SessionSummary(id: "task-polish", cwd: "\(code)/web", title: "Polish the export modal copy", lastActivity: .now - 7200, branch: "usage-export"),
            SessionSummary(id: "task-removed", cwd: "\(code)/billing", title: "Retry the usage export on timeout", lastActivity: .now - 9000, issueRefs: [usage]),
            SessionSummary(id: "task-infra", cwd: "\(code)/infra", title: "Tidy the CI pipeline", lastActivity: .now - 10_000),
        ] + (reviewing ? [
            SessionSummary(id: "task-usage-docs", cwd: "\(code)/billing", title: "Document the usage export columns", lastActivity: .now - 1800, branch: "usage-docs", issueRefs: [usage]),
            SessionSummary(id: "task-parent", cwd: tasksReviewParent, title: "Compare the export in both repositories", lastActivity: .now - 20_000),
        ] : [])
        let url = { (repository: String, number: Int) in URL(string: "https://github.com/\(repository)/pull/\(number)")! }
        return (
            sessions,
            [RepositoryRoot.resolve("\(code)/billing"): "acme/billing", RepositoryRoot.resolve("\(code)/web"): "acme/web", RepositoryRoot.resolve("\(code)/infra"): "acme/infra"],
            [
                PullRequestBranch(repository: "acme/billing", branch: "usage-export"): PullRequest(number: 61, url: url("acme/billing", 61), title: "Usage export endpoint", state: .open, closingIssues: [ClosingIssue(ref: usage, title: "Usage export for invoices", state: .open)]),
                PullRequestBranch(repository: "acme/billing", branch: "fix/invoice-rounding"): PullRequest(number: 212, url: url("acme/billing", 212), title: "Fix rounding in invoice totals", state: .open, closingIssues: [ClosingIssue(ref: rounding, title: "Invoice totals round the wrong way", state: .completed)]),
                PullRequestBranch(repository: "acme/billing", branch: "chore/cleanup"): PullRequest?.none,
                PullRequestBranch(repository: "acme/web", branch: "feat/export-button"): PullRequest?.none,
                PullRequestBranch(repository: "acme/web", branch: "feat/rounded-totals"): PullRequest?.none,
                PullRequestBranch(repository: "acme/web", branch: "usage-export"): PullRequest?.none,
            ].merging(reviewing ? [
                PullRequestBranch(repository: "acme/billing", branch: "usage-export"): PullRequest(number: 61, url: url("acme/billing", 61), title: "Usage export endpoint", state: .open, checks: .passed, closingIssues: [ClosingIssue(ref: usage, title: "Usage export for invoices", state: .open)]),
                PullRequestBranch(repository: "acme/billing", branch: "usage-docs"): PullRequest(number: 62, url: url("acme/billing", 62), title: "Document the usage export", state: .draft, checks: .running),
                PullRequestBranch(repository: "acme/web", branch: "feat/export-button"): PullRequest(number: 89, url: url("acme/web", 89), title: "Usage export in dashboard", state: .open, checks: .failed),
                PullRequestBranch(repository: "acme/infra", branch: "ci-cache"): PullRequest?.none,
            ] : [:]) { $1 },
            TaskState(tasks: [StoredTask(id: "task:fixture-usage", issue: usage, origin: .auto, sessionIDs: ["task-usage-api"], excluded: ["task-removed"])])
        )
    }()

    static let fixtureTasks = taskFixtures?.tasks
    static let fixtureSessions = inboxFixtures?.sessions ?? taskFixtures?.sessions ?? (!pullRequestFixtures.isEmpty ? pullRequestFixtures.map(\.session) : launcherKeys != nil ? hubFolders : nil)
    private static let fixtureRepository = UserDefaults.standard.string(forKey: "snapshotReviewRepository") ?? "acme/billing"
    static let fixtureRepositories = inboxFixtures?.repositories ?? taskFixtures?.repositories ?? Dictionary(pullRequestFixtures.map { (RepositoryRoot.resolve($0.session.cwd), String?.some(fixtureRepository)) }) { first, _ in first }
    private static let fixtureChecks = (UserDefaults.standard.string(forKey: "snapshotChecks") ?? "").split(separator: "|", omittingEmptySubsequences: false).map { PullRequestChecks.State(rawValue: String($0)) }
    static let fixturePullRequests = inboxFixtures?.pullRequests ?? taskFixtures?.pullRequests ?? Dictionary(pullRequestFixtures.enumerated().compactMap { index, item in
        item.session.branch.map { branch in
            var pullRequest = item.pullRequest
            pullRequest?.checks = index < fixtureChecks.count ? fixtureChecks[index] : nil
            return (PullRequestBranch(repository: fixtureRepository, branch: branch), pullRequest)
        }
    }) { first, _ in first }
    static let fixtureInbox = inboxFixtures?.inbox
    #else
    static let fixtureSessions: [SessionSummary]? = nil
    static let fixtureTasks: TaskState? = nil
    static let launcherKeys: String? = nil
    static let fixtureRepositories: [String: String?] = [:]
    static let fixturePullRequests: [PullRequestBranch: PullRequest?] = [:]
    static let fixtureInbox: [InboxPullRequest]? = nil
    static let fixturePullRequestDetail: PullRequestDetail? = nil
    #endif

    static func forcedSelection(in groups: [SessionGroup]) -> SidebarItem? {
        #if DEBUG
        let index = UserDefaults.standard.integer(forKey: "snapshotSelectRow")
        guard index > 0, let sessions = groups.first(where: { !$0.sessions.isEmpty })?.sessions, index <= sessions.count else { return nil }

        return .session(sessions[index - 1].id)
        #else
        return nil
        #endif
    }

    #if DEBUG
    static let launcherQuery = UserDefaults.standard.string(forKey: "snapshotLauncher") ?? UserDefaults.standard.string(forKey: "snapshotSearch") ?? UserDefaults.standard.string(forKey: "snapshotPalette") ?? UserDefaults.standard.string(forKey: "snapshotPullRequests") ?? ""
    #else
    static let launcherQuery = ""
    #endif

    #if DEBUG
    static let forcedHover = Set((UserDefaults.standard.string(forKey: "snapshotHover") ?? "").split(separator: "|").map(String.init))
    static let expandedGroups = Set((UserDefaults.standard.string(forKey: "snapshotExpandedGroups") ?? "").split(separator: "|").map(String.init))
    #else
    static let forcedHover: Set<String> = []
    static let expandedGroups: Set<String> = []
    #endif

    static func capture(to output: URL, store: Store) async {
        #if DEBUG
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let path = UserDefaults.standard.string(forKey: "snapshotCustomGroups"), let data = FileManager.default.contents(atPath: path) {
            store.customGroups = (try? JSONDecoder().decode([CustomGroup].self, from: data)) ?? []
        }
        if let path = UserDefaults.standard.string(forKey: "snapshotLanguageServers"), let data = FileManager.default.contents(atPath: path) {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[LanguageServerEntry.storageKey] = String(decoding: data, as: UTF8.self)
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        await store.waitForScan()
        if UserDefaults.standard.bool(forKey: "snapshotRemote") { store.remote.update() }
        if UserDefaults.standard.bool(forKey: "snapshotFakeWaiting") {
            for (step, waiting) in [false, true, true, false, true].enumerated() {
                if step == 2, let session = store.groups.first(where: { !$0.sessions.isEmpty })?.sessions.first {
                    store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                    store.tabs = store.tabs.map { Tab(id: $0.id, kind: .claude, cwd: session.cwd, sessionID: session.id, terminal: $0.terminal) }
                }
                print("fake first session waiting: \(waiting), in a Berth tab: \(step >= 2)")
                store.fakeWaiting = waiting
                store.refreshLive()
                print("busy sessions: \(store.busySessionCount)")
            }
        }
        if UserDefaults.standard.bool(forKey: "snapshotShell") {
            try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "berth-shell-starts")
            store.openShell(cwd: store.activeSessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
            store.openShell(cwd: store.activeSessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path, command: "/bin/zsh -c 'printf \"\\033]2;npm run dev\\007\"; echo VITE ready; echo started >> \(NSTemporaryDirectory())berth-shell-starts; sleep 600'")
        }
        if UserDefaults.standard.bool(forKey: "snapshotClaudeTab") {
            store.openShell(cwd: store.activeSessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
            store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: $0.cwd, sessionID: nil, terminal: $0.terminal) : $0 }
        }
        if let path = UserDefaults.standard.string(forKey: "snapshotShellCd"), let shell = store.terminals.first {
            Task {
                try? await Task.sleep(for: .seconds(2))
                _ = shell.terminal.paste(text: "cd \(path)")
                _ = shell.terminal.sendKey(.enter)
            }
        }
        let archiveRow = UserDefaults.standard.integer(forKey: "snapshotArchiveRow")
        if archiveRow > 0, let sessions = store.groups.first(where: { !$0.sessions.isEmpty })?.sessions, archiveRow <= sessions.count {
            store.archive(sessions[archiveRow - 1].id)
        }
        if UserDefaults.standard.bool(forKey: "snapshotPinned") {
            for session in store.groups.compactMap(\.sessions.first).suffix(2).reversed() { store.pin(session.id) }
        }
        let topSessions = store.groups.first { !$0.sessions.isEmpty }?.sessions ?? []
        if UserDefaults.standard.bool(forKey: "snapshotFlagged") {
            for session in topSessions.enumerated().filter({ [0, 2].contains($0.offset) }).map(\.element) { store.flag(session.id) }
        }
        if UserDefaults.standard.bool(forKey: "snapshotTasks") {
            try? await Task.sleep(for: .milliseconds(500))
            for task in store.sessionTasks {
                print("task \(task.title) | issue \(task.issue.map { "#\($0.number)" } ?? "none") | members \(task.sessions.map(\.id))")
            }
            print("stored: \(store.tasks.tasks.map { "\($0.id) \($0.sessionIDs) excluded \($0.excluded)" })")
            print("suggestions: \(store.taskSuggestions.map { "\($0.key) -> \($0.value.key) task \($0.value.taskID ?? "new") sessions \($0.value.sessionIDs)" }.sorted())")
            print("sidebar: \(store.sidebarGroups.map { "\($0.group.title) \($0.entries.map { "\($0)" })" })")
        }
        if let filters = UserDefaults.standard.string(forKey: "snapshotSidebarFilter") {
            for filter in filters.split(separator: "|", omittingEmptySubsequences: false).map(String.init) {
                store.sidebarFilter = filter
                let layout = store.sidebarLayout
                let title = { (id: String) in store.sessionsByID[id]?.title ?? id }
                let terminals = layout.terminalIDs.compactMap { id in store.tabs.first { $0.id == id }?.terminal.title }
                let groups = layout.groups.map { group in "\(group.source.title): \(group.entries.map { entry in entry.memberIDs.isEmpty ? title(entry.id) : "task \(store.sessionTasks.first { $0.id == entry.id }?.title ?? "?") \(entry.memberIDs.map(title))" })" }
                print("filter \(filter.debugDescription): terminals \(terminals), pinned \(layout.pinnedIDs.map(title)), groups \(groups), archived \(layout.archivedIDs.map(title)), no matches \(layout.hasNoMatches)")
            }
        }
        if UserDefaults.standard.bool(forKey: "snapshotUnread") {
            for session in topSessions.enumerated().filter({ [1, 3].contains($0.offset) }).map(\.element) { store.markUnread(session.id) }
        }
        if UserDefaults.standard.bool(forKey: "snapshotFakeContext") {
            let sessions = Array(topSessions.prefix(4))
            store.fakeContexts = Dictionary(uniqueKeysWithValues: zip(sessions, [68_000, 126_000, 162_000, 188_000]).map { session, tokens in
                (session.id, SessionContext(model: "claude-opus-5-5", tokens: tokens, window: 200_000, modelName: "Opus 5.5"))
            })
            let opened = sessions.suffix(2)
            for _ in opened { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
            store.tabs = store.tabs.dropLast(opened.count) + zip(store.tabs.suffix(opened.count), opened).map { Tab(id: $0.id, kind: .claude, cwd: $1.cwd, sessionID: $1.id, terminal: $0.terminal) }
            store.selectedTabID = store.tabs.last?.id
            store.refresh()
            await store.waitForScan()
        }
        if store.selection == nil, let forced = forcedSelection(in: store.groups) { store.sidebarCursor = forced }
        if UserDefaults.standard.bool(forKey: "snapshotArchiveTab") {
            for _ in 0..<2 { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
            store.tabs = store.tabs.map { Tab(id: $0.id, kind: .claude, cwd: $0.cwd, sessionID: UUID().uuidString.lowercased(), terminal: $0.terminal) }
        }
        if UserDefaults.standard.bool(forKey: "snapshotHarbor") {
            let faked = store.liveBySession.values.filter { $0.pid == 1 }
            for _ in faked { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path, command: UserDefaults.standard.string(forKey: "snapshotRemoteLog").map { "/usr/bin/tee -a '\($0)'" }) }
            store.tabs = zip(store.tabs, faked).map { Tab(id: $0.id, kind: .claude, cwd: $1.cwd, sessionID: $1.sessionId, terminal: $0.terminal) }
            store.selectedTabID = store.tabs.first?.id
            store.isHarborShown = true
            print("harbor tabs: \(store.tabs.compactMap(\.sessionID).compactMap { store.liveBySession[$0]?.status }), busy sessions \(store.busySessionCount)")
        }
        if UserDefaults.standard.bool(forKey: "snapshotUnloadIdle") {
            let labels = ["idle", "touched", "selected", "pinned", "busy", "waiting", "attach", "dead"]
            let pinned = store.activeSessions.min { $0.lastActivity < $1.lastActivity }?.id ?? "probe-pinned"
            let ids = labels.map { $0 == "pinned" ? pinned : "probe-\($0)" }
            store.pin(pinned)
            let longAgo = Int((Date.now.timeIntervalSince1970 - 3600) * 1000)
            store.fakeLiveSessions = zip(labels, ids).filter { $0.0 != "dead" }.compactMap { label, id in
                let status = ["busy", "waiting"].contains(label) ? label : "idle"
                let attach = label == "attach" ? #","kind":"bg","jobId":"job-1""# : ""
                let json = #"{"pid":1,"sessionId":"\#(id)","cwd":"/","status":"\#(status)","statusUpdatedAt":\#(longAgo)\#(attach)}"#
                return try? JSONDecoder().decode(LiveSession.self, from: Data(json.utf8))
            }
            for _ in labels { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
            store.tabs = zip(store.tabs, ids).map { Tab(id: $0.id, kind: .claude, cwd: $0.cwd, sessionID: $1, terminal: $0.terminal) }
            store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            let terminal = store.selectedTabID
            store.activate(.tab(store.tabs[2].id))
            store.selectedTabID = terminal
            let label: (Tab) -> String = { $0.kind == .shell ? "terminal" : labels[ids.firstIndex(of: $0.sessionID ?? "") ?? 0] }
            print("unload threshold \(UserDefaults.standard.double(forKey: GeneralSettings.unloadIdleKey)) s, pinned still pinned: \(store.pinnedSessions.contains { $0.id == pinned })")
            store.unloadIdleTabs()
            print("right after opening, kept: \(store.tabs.map(label))")
            try? await Task.sleep(for: .seconds(3))
            store.selectedTabID = store.tabs[1].id
            store.selectedTabID = terminal
            let before = store.tabs.map(label)
            store.unloadIdleTabs()
            let kept = store.tabs.map(label)
            print("after 3 s, unloaded: \(before.filter { !kept.contains($0) }), kept: \(kept), selected: \(store.tabs.first { $0.id == store.selectedTabID }.map(label) ?? "-")")
        }
        if let sessionID = UserDefaults.standard.string(forKey: "snapshotResume") {
            store.activate(.session(sessionID))
        }
        let reviewFolder = UserDefaults.standard.string(forKey: "snapshotReview")
        let createPullRequestClick = UserDefaults.standard.string(forKey: "snapshotReviewCreatePullRequest")?.split(separator: ",").compactMap { Double($0) }
        if let reviewFolder {
            store.openShell(cwd: reviewFolder, command: createPullRequestClick != nil ? UserDefaults.standard.string(forKey: "snapshotRemoteLog").map { "/usr/bin/tee -a '\($0)'" } : nil)
            if createPullRequestClick != nil, let live = try? JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":1,"sessionId":"snapshot-review","cwd":"\#(reviewFolder)","status":"idle","startedAt":0}"#.utf8)) {
                store.fakeLiveSessions = [live]
                store.refreshLive()
            }
            store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: reviewFolder, sessionID: "snapshot-review", terminal: $0.terminal) : $0 }
            if AppAction.showChanges.isAvailable(in: store) { AppAction.showChanges.perform(on: store) }
            store.reviewModels["snapshot-review"]?.comments = [ReviewComment(id: "fixture", path: "README.md", line: 3, endLine: 5, text: "Fixture comment: tighten this paragraph.", snippet: "")]
        }
        if UserDefaults.standard.bool(forKey: "snapshotTasksReview") { prepareTasksReview(store: store) }
        if let cwd = UserDefaults.standard.string(forKey: "snapshotClaude") {
            store.openClaude(cwd: cwd, checkout: .main)
        }
        if let version = UserDefaults.standard.string(forKey: "snapshotRestartBanner") {
            store.updater.showPendingRestart(version: version, deadline: .now + 18)
        }
        if UserDefaults.standard.string(forKey: "snapshotLauncher") != nil { store.launcherMode = .newSession }
        if UserDefaults.standard.string(forKey: "snapshotSearch") != nil { store.launcherMode = .search }
        if UserDefaults.standard.string(forKey: "snapshotPalette") != nil { store.launcherMode = .palette }
        if let query = UserDefaults.standard.string(forKey: "snapshotPullRequests") {
            let ranked = PullRequestInbox.rank(query, in: store.inbox ?? [], now: .now)
            print("pull requests for \"\(query)\": \(ranked.pullRequests.count) shown, \(ranked.older) older hidden, toolbar count \(store.inbox?.count { $0.role == .reviewRequested } ?? 0)")
            for pullRequest in ranked.pullRequests {
                let opening = store.opening(of: pullRequest)
                let action = if case let .session(session) = opening {
                    "resume \(session.id)"
                } else if case let .worktree(folder) = opening {
                    "new worktree session in \(URL(filePath: folder).lastPathComponent)"
                } else {
                    "notice: No local checkout of \(pullRequest.repository)"
                }
                print("  \(pullRequest.role.title) | \(pullRequest.title) | \(pullRequest.repository) #\(pullRequest.number) | \(pullRequest.isDraft ? "draft" : "open") | checks \(pullRequest.checks?.rawValue ?? "none") | \(pullRequest.reviewDecision?.rawValue ?? "no decision") | @\(pullRequest.author ?? "-") | updated \(age(since: pullRequest.updatedAt)) | sessions \(store.sessions(for: pullRequest).map(\.id)) | enter: \(action)")
            }
            if UserDefaults.standard.string(forKey: "snapshotLauncherRole") == "reviewRequested" { store.launcherRole = .reviewRequested }
            if launcherKeys == nil { store.launcherMode = .pullRequests }
        }
        let editedGroup = UserDefaults.standard.string(forKey: "snapshotEditGroup").map { name in
            store.customGroups.first { $0.name == name } ?? CustomGroup(name: "", rules: [])
        }
        let servers = LanguageServerEntry.configured(UserDefaults.standard.string(forKey: LanguageServerEntry.storageKey))
        let editedServer = UserDefaults.standard.string(forKey: "snapshotEditServer").map { id in servers.first { $0.id == id } ?? LanguageServerEntry(name: "", command: "") }
        let showsStats = UserDefaults.standard.bool(forKey: "snapshotStats")
        let root = editedGroup.map { AnyView(GroupEditor(group: $0).environment(\.ghosttyTheme, store.theme).preferredColorScheme(store.theme.isDark ? .dark : .light)) }
            ?? editedServer.map { AnyView(LanguageServerEditor(server: $0, servers: .constant(servers)).preferredColorScheme(store.theme.isDark ? .dark : .light)) } ?? AnyView(showsStats ? AnyView(StatsView()) : AnyView(ContentView()))
        let hosting = NSHostingController(rootView: root.environment(store).environment(\.openURL, OpenURLAction { url in
            print("snapshot openURL \(url)")
            return .handled
        }))
        hosting.sceneBridgingOptions = .all
        let window = UnconstrainedWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(editedGroup != nil || editedServer != nil ? hosting.view.fittingSize : showsStats ? NSSize(width: 960, height: 800) : reviewFolder != nil || UserDefaults.standard.bool(forKey: "snapshotTasksReview") ? NSSize(width: UserDefaults.standard.object(forKey: "snapshotReviewWidth") == nil ? 1600 : UserDefaults.standard.double(forKey: "snapshotReviewWidth"), height: 900) : NSSize(width: 1200, height: 760))
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        if UserDefaults.standard.bool(forKey: "snapshotTasksReview") { await captureTasksReview(store: store, window: window, output: output) }
        if reviewFolder != nil, let model = store.reviewModels["snapshot-review"] {
            let deadline = Date.now + 30
            while Date.now < deadline, model.error == nil, model.selectedDocument.flatMap({ model.contents[$0] }) == nil {
                if let changes = model.changes, model.selectedTab == nil {
                    if UserDefaults.standard.bool(forKey: "snapshotReviewNoFile") { break }
                    let requested = UserDefaults.standard.string(forKey: "snapshotReviewFile").map { $0.hasPrefix("committed:") ? ReviewDocument(path: String($0.dropFirst("committed:".count)), compare: .committed) : model.workingDocument($0) }
                    guard let document = requested ?? changes.uncommitted.first.map({ ReviewDocument(path: $0.path, compare: .uncommitted) }) ?? changes.committed.first.map({ ReviewDocument(path: $0.path, compare: .committed) }) else { break }

                    model.open(document)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let ref = UserDefaults.standard.string(forKey: "snapshotReviewBase"), let changes = model.changes {
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments[ReviewModel.baseBranchesKey] = [changes.root: [changes.branch: ref]]
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                await model.load()
            }
            try? await Task.sleep(for: .seconds(1))
            print("review \(model.changes.map { "\($0.branch) → \($0.base ?? "-"), fetch error \($0.fetchError ?? "-")" } ?? "error \(model.error.map(ReviewModel.describe) ?? "timed out")")")
            print("review card \(model.status.map { "base \(model.changes?.base ?? "-") (\(model.changes?.baseReason?.rawValue ?? "-")), bases \(model.changes?.bases.map { "\($0.ref) \($0.distance)" } ?? []), default branch \(model.changes?.isDefaultBranch == true), ahead \($0.ahead), behind \($0.behind), upstream \($0.upstream.map { "\($0.name) +\($0.ahead) -\($0.behind)" } ?? "-"), commits \($0.commits.map { "\($0.sha) \($0.isPushed ? "pushed" : "unpushed")" }), total \(model.changes?.total.map { "+\($0.additions) -\($0.deletions)" } ?? "-")" } ?? "none"), pull request details \(model.pullRequestDetails)")
            for (section, files) in [("uncommitted", model.changes?.uncommitted ?? []), ("committed", model.changes?.committed ?? [])] {
                for file in files { print("  \(section) \(file.status.rawValue) \(file.path) +\(file.additions.map(String.init) ?? "?") -\(file.deletions.map(String.init) ?? "?")") }
            }
            if UserDefaults.standard.bool(forKey: "reviewChangesAsTree") {
                func lines(_ nodes: [ReviewFileTree], depth: Int) -> [String] {
                    nodes.flatMap { ["    " + String(repeating: "  ", count: depth) + $0.name + ($0.children == nil ? "" : "/")] + lines($0.children ?? [], depth: depth + 1) }
                }
                for (section, files) in [("uncommitted", model.changes?.uncommitted ?? []), ("committed", model.changes?.committed ?? [])] where !files.isEmpty {
                    print("  \(section) tree\n" + lines(ReviewFileTree.compactNodes(files.map(\.path)), depth: 0).joined(separator: "\n"))
                }
            }
            print("review files tree \(model.tree.map { $0.children == nil ? $0.name : "\($0.name)/ (\($0.children?.count ?? 0))" }), expanded folders \(model.expandedFolders.sorted())")
            print("review selected \(describe(model)), contents loaded \(model.selectedDocument.flatMap { model.contents[$0] } != nil), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let shownSides = descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }
            let sides = shownSides.count == 1 ? [shownSides[0].unifiedOriginal, shownSides[0]].compactMap(\.self) : shownSides
            let clips = { sides.map { "\($0.enclosingScrollView?.contentView.bounds.minY ?? -1)" }.joined(separator: "/") }
            let save = { (suffix: String) in
                guard let image = image(of: window) else { return }

                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
            }
            let click = { (point: [Double]) in
                let location = NSPoint(x: point.first ?? 0, y: (window.contentView?.frame.height ?? 0) - (point.last ?? 0))
                let event = { (type: NSEvent.EventType) in NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) }
                event(.leftMouseUp).map { NSApp.postEvent($0, atStart: false) }
                event(.leftMouseDown).map(window.sendEvent)
            }
            if let point = UserDefaults.standard.string(forKey: "snapshotReviewRefresh")?.split(separator: ",").compactMap({ Double($0) }), let branch = model.changes?.branch {
                let lookup = { store.pullRequest(in: model.folder, branch: branch).map { "\($0.repository) \($0.pullRequest.map { "#\($0.number) \($0.state.rawValue)" } ?? "no PR")" } ?? "unknown" }
                print("before refresh: \(branch) \(lookup())")
                click(point)
                try? await Task.sleep(for: .seconds(8))
                print("after refresh: \(branch) \(lookup())")
                save(".refreshed.png")
            }
            if let point = createPullRequestClick {
                let log = { (try? String(contentsOfFile: UserDefaults.standard.string(forKey: "snapshotRemoteLog") ?? "", encoding: .utf8)).debugDescription }
                window.makeFirstResponder(nil)
                click(point)
                try? await Task.sleep(for: .seconds(1))
                print("after create pull request click: log \(log()), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"), notice \(model.notice ?? "-")")
                save(".pr.png")
                _ = store.tab(forSession: "snapshot-review")?.terminal.sendKey(.enter)
                try? await Task.sleep(for: .seconds(1))
                print("after Enter: log \(log())")
            }
            let report = { (label: String) in
                let shown = descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }
                let sides = shown.count == 1 ? [shown[0].unifiedOriginal, shown[0]].compactMap(\.self) : shown
                for (index, side) in sides.enumerated() {
                    let lineViews = descendants(side).filter { "\(type(of: $0))" == "_NSTextViewportElementView" && !$0.isHidden }.map { side.convert($0.frame, from: $0.superview) }.filter { $0.intersects(side.visibleRect) }
                    let offFragment = lineViews.filter { frame in
                        let origin = side.textContainerOrigin
                        guard let fragment = side.textLayoutManager?.textLayoutFragment(for: CGPoint(x: 0, y: frame.midY - origin.y)) else { return true }

                        return frame != fragment.renderingSurfaceBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x, dy: fragment.layoutFragmentFrame.minY + origin.y)
                    }
                    print("\(label) \(index == 0 ? "left" : "right") line views: \(lineViews.count) on screen, \(offFragment.count) off their layout fragment\(offFragment.prefix(3).map { " \($0)" }.joined())")
                    print("\(label) \(index == 0 ? "left" : "right"): TextKit 2 \(side.textLayoutManager != nil), layoutManager requests \(side.layoutManagerRequests), height \(side.frame.height), usage \(side.textLayoutManager?.usageBoundsForTextContainer.height ?? -1), clip y \(side.enclosingScrollView?.contentView.bounds.minY ?? -1), reserved \(side.reserved), inline \(side.subviews.compactMap { $0 as? ReviewInlineComment }.filter { !$0.isHidden }.map { "\($0.frame)" })")
                }
                guard sides.count == 2 else { return }

                let rows = sides.map { side in
                    var tops: [Int: CGFloat] = [:]
                    side.enumerateRows(in: side.bounds) { line, row, _, startsLine in if startsLine { tops[line] = row.minY } }
                    return tops
                }
                let diff = ReviewDiff(original: sides[0].string, modified: sides[1].string)
                let checks = diff.hunks.compactMap { hunk in rows[0][hunk.originalLines.upperBound].flatMap { left in rows[1][hunk.modifiedLines.upperBound].map { (hunk, left, $0) } } }
                let unchanged = zip((0..<diff.original.lineCount).filter { !diff.original.changedLines.contains($0) }, (0..<diff.modified.lineCount).filter { !diff.modified.changedLines.contains($0) })
                let shifted = unchanged.count(where: { pair in rows[0][pair.0].flatMap { left in rows[1][pair.1].map { left != $0 } } ?? false })
                let arithmetic = unchanged.count(where: { pair in rows[1][pair.1].map { $0 != sides[1].top(ofRow: (sides[1].side ?? diff.modified).rows[pair.1]) } ?? false })
                print("\(label) \(sides[1].unifiedOriginal == nil ? "side by side" : "unified, width \(sides[1].frame.width) for \(sides[1].minimumWidth), text is the file \(sides[1].string == model.drafts[model.selectedDocument?.path ?? ""] ?? model.selectedDocument.flatMap { model.contents[$0]?.modified }.flatMap { if case let .text(text) = $0 { text } else { nil } } ?? "")"), height \(sides[1].frame.height) for top(ofRow: rowCount) \(sides[1].top(ofRow: sides[1].side?.rowCount ?? 0)), pane \(sides[1].enclosingScrollView?.superview?.frame.width ?? -1) hunks \(diff.hunks.count), checked \(checks.count), misaligned \(checks.count(where: { $0.1 != $0.2 })), unchanged pairs misaligned \(shifted), off top(ofRow:) \(arithmetic): " + checks.prefix(6).map { "\($0.0.originalLines)/\($0.0.modifiedLines) next row y \($0.1)/\($0.2)" }.joined(separator: ", "))
            }
            report("review")
            if let ratio = UserDefaults.standard.string(forKey: "snapshotReviewSplit").flatMap(Double.init), let file = model.selectedDocument {
                let saved = UserDefaults.standard.object(forKey: "reviewSplitRatio")
                let split = { descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.last?.enclosingScrollView?.superview?.superview as? NSSplitView }
                let press = { (x: CGFloat?, clickCount: Int) in
                    guard let split = split() else { return }

                    let divider = split.subviews[0].frame.maxX + split.dividerThickness / 2
                    let event = { (type: NSEvent.EventType, x: CGFloat) in NSEvent.mouseEvent(with: type, location: split.convert(NSPoint(x: x, y: split.bounds.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) }
                    event(.leftMouseDragged, x ?? divider).map { NSApp.postEvent($0, atStart: false) }
                    event(.leftMouseUp, x ?? divider).map { NSApp.postEvent($0, atStart: false) }
                    event(.leftMouseDown, divider).map(window.sendEvent)
                }
                let state = { (label: String) in
                    let texts = descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }
                    print("split \(label): sides \(split()?.subviews.map(\.frame.width) ?? []), stored \(UserDefaults.standard.object(forKey: "reviewSplitRatio").map { "\($0)" } ?? "unset"), clip x \(texts.map { $0.enclosingScrollView?.contentView.bounds.minX ?? -1 }), \(texts.last?.unifiedOriginal == nil ? "side by side" : "unified")")
                }
                sides.last.map { $0.scroll(NSPoint(x: 40, y: $0.visibleRect.minY)) }
                state("before drag")
                press(split().map { CGFloat(ratio) * ($0.bounds.width - $0.dividerThickness) }, 1)
                try? await Task.sleep(for: .seconds(1))
                state("dragged to \(ratio)")
                report("split")
                save(".split.png")
                store.closeDiff()
                try? await Task.sleep(for: .seconds(1))
                model.open(file)
                try? await Task.sleep(for: .seconds(2))
                state("closed and reopened")
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments[ReviewDiffLayout.key] = ReviewDiffLayout.inline.rawValue
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                try? await Task.sleep(for: .seconds(1))
                state("unified")
                report("unified")
                save(".split-unified.png")
                arguments[ReviewDiffLayout.key] = ReviewDiffLayout.sideBySide.rawValue
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                try? await Task.sleep(for: .seconds(1))
                state("side by side again")
                press(nil, 1)
                press(nil, 2)
                try? await Task.sleep(for: .seconds(1))
                state("double-clicked")
                report("reset")
                save(".split-reset.png")
                UserDefaults.standard.set(saved, forKey: "reviewSplitRatio")
            }
            if UserDefaults.standard.bool(forKey: GeneralSettings.languageServersKey), let file = model.selectedDocument {
                let right = { descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.last }
                let point = { (textView: ReviewTextView, spec: String) -> NSPoint? in
                    let numbers = spec.split(separator: ":").compactMap { Int($0) }
                    guard numbers.count == 2 else { return nil }

                    let offset = textView.offset(of: LanguageServerPosition(line: numbers[0] - 1, character: numbers[1] - 1))
                    return textView.segments(of: NSRange(location: offset, length: 1)).first.map { NSPoint(x: $0.rect.midX, y: $0.rect.midY) }
                }
                let mouse = { (textView: ReviewTextView, type: NSEvent.EventType, location: NSPoint, flags: NSEvent.ModifierFlags) in
                    guard let event = NSEvent.mouseEvent(with: type, location: textView.convert(location, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .mouseMoved ? 0 : 1) else { return }
                    guard type == .leftMouseDown else { return textView.mouseMoved(with: event) }

                    NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow, modifierFlags: flags, timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0).map { NSApp.postEvent($0, atStart: false) }
                    textView.mouseDown(with: event)
                }
                let crop = { (suffix: String, view: NSView, rect: NSRect) in
                    guard let image = image(of: window) else { return }

                    let scale = CGFloat(image.width) / window.frame.width
                    let inWindow = view.convert(rect, to: nil)
                    let pixels = CGRect(x: inWindow.minX * scale, y: (window.frame.height - inWindow.maxY) * scale, width: inWindow.width * scale, height: inWindow.height * scale)
                    guard let cropped = image.cropping(to: pixels.integral) else { return }

                    try? NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
                }
                let clock = ContinuousClock.now
                while ContinuousClock.now - clock < .seconds(120), file.compare != .committed, right()?.diagnostics.isEmpty != false { try? await Task.sleep(for: .milliseconds(250)) }
                let waited = ContinuousClock.now - clock
                var settled = (diagnostics: right()?.diagnostics ?? [], at: ContinuousClock.now)
                while ContinuousClock.now - settled.at < .seconds(3), ContinuousClock.now - clock < .seconds(150) {
                    try? await Task.sleep(for: .milliseconds(250))
                    if let shown = right()?.diagnostics, shown != settled.diagnostics { settled = (shown, .now) }
                }
                if let textView = right(), let gutter = textView.gutter {
                    print("diagnostics shown after \(waited): " + textView.diagnostics.map { "\($0.range.start.line + 1):\($0.range.start.character + 1)-\($0.range.end.line + 1):\($0.range.end.character + 1) \($0.severity.map { "\($0)" } ?? "-") \($0.message.debugDescription) (\($0.source ?? "-")) tags \($0.tags.map { "\($0)" }.sorted())" }.joined(separator: "; "))
                    if let first = textView.diagnostics.first, let segment = textView.segments(of: NSRange(location: textView.offset(of: first.range.start), length: 1)).first {
                        let middle = NSPoint(x: segment.rect.midX, y: segment.rect.midY)
                        let mark = gutter.convert(middle, from: textView)
                        print("diagnostic tooltip: gutter \(gutter.view(gutter, stringForToolTip: 0, point: NSPoint(x: 7, y: mark.y), userData: nil).debugDescription)")
                        crop(".diagnostic.png", gutter, NSRect(x: 0, y: mark.y - 40, width: gutter.bounds.width + 520, height: 80))
                    }
                }
                let servers = {
                    ProcessAncestry.descendants().map(\.pid).filter { pid in
                        var name = [CChar](repeating: 0, count: 256)
                        proc_name(pid, &name, 256)
                        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "sourcekit-lsp"
                    }.sorted()
                }
                if UserDefaults.standard.bool(forKey: "snapshotReviewToggleServers") {
                    let setEnabled = { (isEnabled: Bool) in
                        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                        arguments[GeneralSettings.languageServersKey] = isEnabled
                        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                    }
                    let before = servers()
                    setEnabled(false)
                    try? await Task.sleep(for: .seconds(3))
                    print("toggle: servers \(before) → off \(servers()), diagnostics \(right()?.diagnostics.count ?? -1)")
                    setEnabled(true)
                    let clock = ContinuousClock.now
                    while ContinuousClock.now - clock < .seconds(30), right()?.diagnostics.isEmpty != false { try? await Task.sleep(for: .milliseconds(250)) }
                    print("toggle: on again \(servers()), diagnostics \(right()?.diagnostics.count ?? -1) after \(ContinuousClock.now - clock)")
                }
                if UserDefaults.standard.bool(forKey: "snapshotReviewCrash"), let other = model.changes?.uncommitted.first(where: { $0.path != file.path })?.path {
                    let killed = servers()
                    killed.forEach { kill($0, SIGKILL) }
                    try? await Task.sleep(for: .seconds(1.5))
                    print("crash: killed \(killed), servers now \(servers()), still showing \(model.selectedDocument?.path ?? "-") with \(right()?.diagnostics.count ?? -1) diagnostics")
                    model.open(model.workingDocument(other))
                    try? await Task.sleep(for: .seconds(2))
                    model.open(file)
                    let clock = ContinuousClock.now
                    while ContinuousClock.now - clock < .seconds(30), servers().isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                    try? await Task.sleep(for: .seconds(3))
                    print("crash: after showing \(other) and \(file) again, servers \(servers()), diagnostics \(right()?.diagnostics.map(\.message) ?? [])")
                }
                let views = { descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView } }
                let peek = { descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewReferencesPeek }.first }
                let clipYs = { views().map { "\($0.enclosingScrollView?.contentView.bounds.minY ?? -1)" }.joined(separator: "/") }
                let locate = { (spec: String) -> (textView: ReviewTextView, clicked: ReviewTextView, point: NSPoint)? in
                    let isLeft = spec.hasPrefix("left:")
                    guard let textView = isLeft ? right()?.unifiedOriginal ?? views().first : right(), let clicked = textView.window == nil || textView.enclosingScrollView?.isHidden == true ? right() : textView, let point = point(textView, isLeft ? String(spec.dropFirst(5)) : spec) else { return nil }

                    return (textView, clicked, point)
                }
                if let spec = UserDefaults.standard.string(forKey: "snapshotReviewHover"), let (_, textView, target) = locate(spec) {
                    let requests = textView.layoutManagerRequests
                    let card = { textView.subviews.first { $0.subviews.first is NSTextField } }
                    let started = ContinuousClock.now
                    while ContinuousClock.now - started < .seconds(60), card() == nil {
                        mouse(textView, .mouseMoved, NSPoint(x: textView.bounds.maxX - 2, y: target.y), [])
                        mouse(textView, .mouseMoved, target, [])
                        try? await Task.sleep(for: .seconds(2))
                    }
                    print("hover \(spec) after \(ContinuousClock.now - started): \(card()?.subviews.map { ($0 as? NSTextField)?.stringValue.debugDescription ?? "———" }.joined(separator: " ") ?? "no card"), card \(card().map { "\($0.frame), label \($0.subviews.first?.frame ?? .zero)" } ?? "-"), visible width \(textView.visibleRect.width), layoutManager requests \(requests) → \(textView.layoutManagerRequests), TextKit 2 \(textView.textLayoutManager != nil)")
                    if let shown = card() { crop(".hover.png", textView, shown.frame.union(NSRect(x: target.x - 60, y: target.y - 20, width: 120, height: 20)).insetBy(dx: -16, dy: -16)) }
                    mouse(textView, .mouseMoved, NSPoint(x: textView.bounds.maxX - 2, y: target.y), [])
                    print("hover after moving away: card \(card() == nil ? "dismissed" : "shown")")
                }
                for spec in (UserDefaults.standard.string(forKey: "snapshotReviewDefinition") ?? "").split(separator: "|").map(String.init) {
                    if model.selectedDocument != file {
                        model.open(file)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    guard let (textView, clicked, target) = locate(spec) else { continue }

                    let requests = textView.layoutManagerRequests
                    let before = views().map { $0.selectedRange() }
                    let clipsBefore = clipYs()
                    mouse(clicked, .mouseMoved, target, .command)
                    try? await Task.sleep(for: .milliseconds(300))
                    crop(".link-\(spec.replacing(":", with: "-")).png", clicked, NSRect(x: target.x - 120, y: target.y - 20, width: 240, height: 40))
                    mouse(clicked, .leftMouseDown, target, .command)
                    let started = ContinuousClock.now
                    let isUnchanged = { model.selectedDocument == file && views().map { $0.selectedRange() } == before && peek() == nil && clipYs() == clipsBefore }
                    while ContinuousClock.now - started < .seconds(20), model.reveal != nil || isUnchanged() {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .seconds(1))
                    if let shown = peek() {
                        print("definition \(spec): is its own definition, peek shows \(shown.title)")
                        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) { shown.list.keyDown(with: escape) }
                        continue
                    }
                    guard !isUnchanged(), let landed = window.firstResponder as? ReviewTextView ?? right() else {
                        print("definition \(spec): no landing after \(ContinuousClock.now - started) (outside the repository or no answer), selected \(model.selectedDocument?.path ?? "-")")
                        continue
                    }

                    let selection = landed.selectedRange()
                    let position = landed.position(ofOffset: selection.location)
                    print("definition \(spec): landed in \(describe(model)) on the \(landed === views().first ? "left" : "right") at \(position.line + 1):\(position.character + 1) selecting \((landed.string as NSString).substring(with: selection).debugDescription), clip y left/right \(descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.map { "\($0.enclosingScrollView?.contentView.bounds.minY ?? -1)" }), first responder is right \(window.firstResponder === landed), layoutManager requests \(requests) → \(landed.layoutManagerRequests), TextKit 2 \(landed.textLayoutManager != nil)")
                    save(".definition-\(spec.replacing(":", with: "-")).png")
                    let landedDocument = model.selectedDocument
                    await model.load()
                    try? await Task.sleep(for: .seconds(1))
                    print("definition \(spec): after Refresh still showing \(landedDocument?.path ?? "-") \(model.selectedDocument == landedDocument && landedDocument.flatMap { model.contents[$0] } != nil), \(describe(model))")
                }
                let key = { (view: NSView, code: UInt16, characters: String, flags: NSEvent.ModifierFlags) in
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) { view.keyDown(with: event) }
                }
                let waitForPeek = { (isShown: Bool) in
                    let started = ContinuousClock.now
                    while ContinuousClock.now - started < .seconds(30), (peek() != nil) != isShown { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                let describePeek = { (shown: ReviewReferencesPeek) in
                    "\(shown.title.debugDescription), preview selects \(shown.previewSelection.debugDescription) at clip y \(shown.previewTop), first responder in peek \((window.firstResponder as? NSView)?.isDescendant(of: shown) == true), in the \(shown.superview === views().first ? "left" : "right") view at \(shown.frame), reserved \(views().map(\.reserved))"
                }
                for spec in (UserDefaults.standard.string(forKey: "snapshotReviewReferences") ?? "").split(separator: "|").map(String.init) {
                    if model.selectedDocument != file {
                        model.open(file)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    guard let (textView, clicked, target) = locate(spec) else { continue }

                    let name = spec.replacing(":", with: "-")
                    let menu = NSEvent.mouseEvent(with: .rightMouseDown, location: clicked.convert(target, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1).flatMap(clicked.menu(for:))
                    print("references \(spec): writing tools off in diff views \(views().map { $0.writingToolsBehavior == .none }), comment field \(ReviewInlineComment(title: "", text: "", kind: .card(onEdit: {}, onDelete: {}), style: clicked.style).field.writingToolsBehavior == .none), context menu \(menu?.items.map(\.title) ?? [])")
                    mouse(clicked, .leftMouseDown, target, .command)
                    await waitForPeek(true)
                    guard let shown = peek() else {
                        print("references \(spec): no peek after ⌘-click, \(describe(model))")
                        continue
                    }

                    print("references \(spec) after ⌘-click: \(describePeek(shown))")
                    for group in shown.outline { print("  \(group)") }
                    report("references \(spec)")
                    save(".references-\(name).png")
                    let resize = UserDefaults.standard.double(forKey: "snapshotReviewReferencesResize")
                    if resize > 0 {
                        window.setContentSize(NSSize(width: resize, height: 900))
                        try? await Task.sleep(for: .seconds(1.5))
                        print("references \(spec) resized to \(resize): \(peek() === shown ? "same peek" : "peek replaced"), \(shown.split.isVertical ? "side by side" : "stacked"), preview \(shown.split.subviews[0].frame), list \(shown.split.subviews[1].frame), column \(shown.list.tableColumns.first?.width ?? -1), \(describePeek(shown))")
                        report("references \(spec) resized")
                        save(".references-\(name)-resized.png")
                    }
                    if let ratio = UserDefaults.standard.string(forKey: "snapshotReviewReferencesSplit").flatMap(Double.init) {
                        let saved = UserDefaults.standard.object(forKey: "reviewReferencesSplitRatio")
                        let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
                        let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
                        method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
                        method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
                        window.makeFirstResponder(nil)
                        window.makeFirstResponder(shown.list)
                        window.becomeKey()
                        try? await Task.sleep(for: .milliseconds(300))
                        print("references split after faking key: selected row emphasized \(shown.list.rowView(atRow: shown.list.selectedRow, makeIfNecessary: false)?.isEmphasized.description ?? "-")")
                        let split = shown.split
                        let drag = { (position: CGFloat?, clickCount: Int) in
                            let divider = (split.isVertical ? split.subviews[0].frame.maxX : split.subviews[0].frame.maxY) + split.dividerThickness / 2
                            let event = { (type: NSEvent.EventType, position: CGFloat) in NSEvent.mouseEvent(with: type, location: split.convert(split.isVertical ? NSPoint(x: position, y: split.bounds.midY) : NSPoint(x: split.bounds.midX, y: position), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1) }
                            event(.leftMouseDragged, position ?? divider).map { NSApp.postEvent($0, atStart: false) }
                            event(.leftMouseUp, position ?? divider).map { NSApp.postEvent($0, atStart: false) }
                            event(.leftMouseDown, divider).map(window.sendEvent)
                        }
                        let state = { (label: String) in
                            print("references split \(label): \(peek() === shown ? "same peek" : "peek replaced") at \(shown.frame), \(split.isVertical ? "side by side" : "stacked"), preview | list \(split.subviews.map { split.isVertical ? $0.frame.width : $0.frame.height }), preview clip x \((split.subviews.first as? NSScrollView)?.contentView.bounds.minX ?? -1), 2 pt past the divider hits the split \(split.hitTest(split.convert(split.isVertical ? NSPoint(x: split.subviews[0].frame.maxX + split.dividerThickness + 2, y: split.bounds.midY) : NSPoint(x: split.bounds.midX, y: split.subviews[0].frame.maxY + split.dividerThickness + 2), to: split.superview)) === split), column \(shown.list.tableColumns.first?.width ?? -1), stored \(UserDefaults.standard.object(forKey: "reviewReferencesSplitRatio").map { "\($0)" } ?? "unset"), selected row emphasized \(shown.list.rowView(atRow: shown.list.selectedRow, makeIfNecessary: false)?.isEmphasized.description ?? "-"), first responder is the list \(window.firstResponder === shown.list)")
                        }
                        state("before drag")
                        drag((1 - CGFloat(ratio)) * ((split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness), 1)
                        try? await Task.sleep(for: .seconds(1))
                        state("dragged to list share \(ratio)")
                        save(".references-\(name)-split.png")
                        drag(nil, 1)
                        drag(nil, 2)
                        try? await Task.sleep(for: .seconds(1))
                        state("double-clicked")
                        UserDefaults.standard.set(saved, forKey: "reviewReferencesSplitRatio")
                    }
                    key(shown.list, 125, "\u{F701}", [])
                    print("references \(spec) after ↓: \(describePeek(shown))")
                    save(".references-\(name)-down.png")
                    let press = { (view: NSView, point: NSPoint, clicks: Int) in
                        let location = view.convert(point, to: nil)
                        let event = { (type: NSEvent.EventType) in NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0) }
                        event(.leftMouseUp).map { NSApp.postEvent($0, atStart: false) }
                        event(.leftMouseDown).map(window.sendEvent)
                    }
                    shown.list.scrollRowToVisible(shown.list.numberOfRows - 1)
                    let lastRow = NSPoint(x: shown.list.rect(ofRow: shown.list.numberOfRows - 1).midX, y: shown.list.rect(ofRow: shown.list.numberOfRows - 1).midY)
                    press(shown.list, lastRow, 1)
                    try? await Task.sleep(for: .milliseconds(300))
                    print("references \(spec) after clicking the last row: \(describePeek(shown))")
                    window.makeFirstResponder(descendants(shown).first { $0 is NSTextView })
                    let previewResponder = window.firstResponder
                    if let responder = previewResponder as? NSView { key(responder, 53, "\u{1B}", []) }
                    await waitForPeek(false)
                    print("references \(spec) after Esc in \(previewResponder.map { "\(type(of: $0))" } ?? "nil"): peek \(peek() == nil ? "closed" : "open"), reserved \(views().map(\.reserved)), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")

                    let numbers = spec.split(separator: ":").compactMap { Int($0) }
                    let reopen = {
                        guard let (textView, clicked, target) = locate(spec) else { return }

                        let menu = NSEvent.mouseEvent(with: .rightMouseDown, location: clicked.convert(target, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1).flatMap(clicked.menu(for:))
                        if clicked === textView, numbers.count == 2 {
                            window.makeFirstResponder(textView)
                            textView.setSelectedRange(NSRange(location: textView.offset(of: LanguageServerPosition(line: numbers[0] - 1, character: numbers[1] - 1)), length: 0))
                            key(textView, 111, "\u{F70F}", .shift)
                        } else if let item = menu?.items.first(where: { $0.title == "Find References" }), let action = item.action {
                            NSApp.sendAction(action, to: item.target, from: item)
                        }
                        await waitForPeek(true)
                    }
                    await reopen()
                    guard let reopened = peek() else {
                        print("references \(spec): no peek after \(clicked === textView ? "⇧F12" : "the context menu")")
                        continue
                    }

                    print("references \(spec) after \(clicked === textView ? "⇧F12" : "the context menu's Find References"): \(describePeek(reopened))")
                    press(reopened, NSPoint(x: reopened.bounds.width - 18, y: 13), 1)
                    await waitForPeek(false)
                    print("references \(spec) after clicking ×: peek \(peek() == nil ? "closed" : "open"), reserved \(views().map(\.reserved))")

                    let land = { (gesture: String, chosen: ReviewReference?) in
                        let started = ContinuousClock.now
                        while ContinuousClock.now - started < .seconds(10), model.reveal != nil || peek() != nil { try? await Task.sleep(for: .milliseconds(100)) }
                        try? await Task.sleep(for: .seconds(1))
                        let landed = window.firstResponder as? ReviewTextView ?? right()
                        let selection = landed?.selectedRange() ?? NSRange()
                        print("references \(spec) after \(gesture) on \(chosen.map { "\($0.path):\($0.location.range.start.line + 1)\($0.isBase ? " (old)" : "")" } ?? "-"): peek \(peek() == nil ? "closed" : "open"), reveal pending \(model.reveal != nil), \(describe(model)), first responder is a diff side \(window.firstResponder is ReviewTextView), \(landed.map { $0 === views().first ? "left" : "right" } ?? "-") selects \(landed.map { "\($0.position(ofOffset: selection.location).line + 1):\($0.position(ofOffset: selection.location).character + 1) \(($0.string as NSString).substring(with: selection).debugDescription)" } ?? "-"), clips \(clipYs())")
                    }
                    await reopen()
                    if let again = peek() {
                        key(again.list, 125, "\u{F701}", [])
                        let chosen = again.selectedReference
                        key(again.list, 36, "\r", [])
                        await land("↩", chosen)
                        save(".references-\(name)-opened.png")
                    }
                    if model.selectedDocument != file {
                        model.open(file)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    await reopen()
                    if let again = peek() {
                        again.list.selectRowIndexes(IndexSet(integer: again.list.numberOfRows - 1), byExtendingSelection: false)
                        if let action = again.list.doubleAction { NSApp.sendAction(action, to: again.list.target, from: again.list) }
                        await land("the list's double-click action", again.selectedReference)
                    }
                }
            }
            if let edit = UserDefaults.standard.string(forKey: "snapshotReviewEdit"), let right = sides.last {
                window.makeFirstResponder(right)
                right.setSelectedRange(NSRange(location: 0, length: 0))
                right.insertText(edit, replacementRange: right.selectedRange())
                try? await Task.sleep(for: .seconds(2))
                print("review after edit: draft \(model.drafts[model.selectedDocument?.path ?? ""] != nil), \(describe(model)), undo \(right.undoManager?.canUndo ?? false), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
                report("edited")
            }
            let scrollY = UserDefaults.standard.double(forKey: "snapshotReviewScroll")
            if scrollY > 0, let right = sides.last {
                right.scroll(NSPoint(x: 0, y: scrollY))
                try? await Task.sleep(for: .milliseconds(500))
                report("scrolled")
            }
            func descendantViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantViews) }
            if let spec = UserDefaults.standard.string(forKey: "snapshotReviewWheel"), sides.count == 2, let separator = spec.firstIndex(of: ":"), let delta = Int32(spec[spec.index(after: separator)...]) {
                let views = descendantViews(window.contentView ?? NSView())
                let targets: [Substring: NSView?] = ["left": sides[0].enclosingScrollView, "right": sides[1].enclosingScrollView, "gutter-left": sides[0].gutter, "minimap": views.first { $0 is ReviewMinimap }, "ruler": views.first { $0 is ReviewOverviewRuler }]
                let area = targets[spec[..<separator]].flatMap(\.self) ?? NSView()
                let point = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
                let target = window.contentView?.hitTest(window.contentView?.superview?.convert(point, from: nil) ?? point)
                let before = clips()
                if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -delta, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cgEvent) { target?.scrollWheel(with: event) }
                try? await Task.sleep(for: .milliseconds(500))
                print("wheel \(spec) over \(target.map { "\(type(of: $0))" } ?? "nil"): clip y left/right \(before) → \(clips())")
            }
            let mouse = { (view: NSView, ys: [CGFloat]) in
                for (index, y) in ys.enumerated() {
                    let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == ys.count - 1 ? .leftMouseUp : .leftMouseDragged
                    guard let event = NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: view.bounds.midX, y: y), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }

                    if type == .leftMouseDown { view.mouseDown(with: event) } else if type == .leftMouseDragged { view.mouseDragged(with: event) } else { view.mouseUp(with: event) }
                }
            }
            if let spec = UserDefaults.standard.string(forKey: "snapshotReviewMinimap"), let minimap = descendantViews(window.contentView ?? NSView()).compactMap({ $0 as? ReviewMinimap }).first, !minimap.isHidden {
                let ys = spec.split(separator: "-").compactMap { Double($0) }.map { CGFloat($0) }
                let before = (clips(), minimap.renders)
                mouse(minimap, ys + [ys.last ?? 0])
                try? await Task.sleep(for: .milliseconds(300))
                print("minimap \(minimap.isHidden ? "hidden" : "shown") \(minimap.frame.size) drag \(spec): clip y left/right \(before.0) → \(clips()), renders \(before.1) → \(minimap.renders)")
            }
            if let y = UserDefaults.standard.string(forKey: "snapshotReviewRuler").flatMap(Double.init), let ruler = descendantViews(window.contentView ?? NSView()).compactMap({ $0 as? ReviewOverviewRuler }).first {
                let before = clips()
                mouse(ruler, [CGFloat(y), CGFloat(y)])
                try? await Task.sleep(for: .milliseconds(300))
                print("ruler \(ruler.frame.size) click \(y): clip y left/right \(before) → \(clips())")
            }
            if let spec = UserDefaults.standard.string(forKey: "snapshotReviewGutter"), sides.count == 2, let separator = spec.firstIndex(of: ":") {
                let side = spec[..<separator] == "left" ? sides[0] : sides[1]
                let lines = spec[spec.index(after: separator)...].split(separator: "-").compactMap { Int($0) }
                let host = sides[1].unifiedOriginal == nil ? side : sides[1]
                let drag = {
                    let ys = lines.map { line in
                        let y = side.top(ofRow: side.side?.rows[line - 1] ?? 0) + side.rowHeight / 2
                        return host.gutter.map { $0.convert(host.convert(NSPoint(x: 0, y: y), to: nil), from: nil).y } ?? 0
                    }
                    if let gutter = host.gutter { mouse(gutter, ys + [ys.last ?? 0]) }
                }
                let draft = { sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment }.first(where: \.field.isEditable) }
                let type = { (characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) in
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }

                    window.sendEvent(event)
                }
                let clock = ContinuousClock.now
                drag()
                let opened = ContinuousClock.now - clock
                try? await Task.sleep(for: .milliseconds(500))
                print("gutter \(spec) opened in \(opened): selected \(sides.map { $0.selectedLines.map { "\($0)" } ?? "-" }), draft \(draft().map { "\($0.frame) in \($0.superview === sides[0] ? "left" : "right")" } ?? "none"), first responder is draft field \(window.firstResponder === draft()?.field)")
                report("draft")
                save(".draft.png")
                type("\u{1B}", 53, [])
                try? await Task.sleep(for: .milliseconds(300))
                print("after esc: draft \(draft() == nil ? "closed" : "open"), selected \(sides.map { $0.selectedLines.map { "\($0)" } ?? "-" }), reserved \(sides[1].reserved)")
                drag()
                try? await Task.sleep(for: .milliseconds(300))
                for (character, keyCode, flags) in [("f", 3, []), ("i", 34, []), ("x", 7, []), ("\r", 36, .shift), ("i", 34, []), ("t", 17, [])] as [(String, UInt16, NSEvent.ModifierFlags)] {
                    type(character, keyCode, flags)
                }
                try? await Task.sleep(for: .milliseconds(300))
                print("typed: field \(draft()?.field.string.debugDescription ?? "-"), Add Comment enabled \(draft()?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Add Comment" }?.isEnabled ?? false), draft height \(draft()?.frame.height ?? -1), reserved \(sides[1].reserved)")
                report("typed")
                type("\r", 36, [])
                try? await Task.sleep(for: .milliseconds(500))
                print("comments: \(model.comments.map { "\($0.path):\($0.line)-\($0.endLine) \($0.side) \($0.compare.map { "\($0)" } ?? "file") \($0.text.debugDescription) snippet \($0.snippet.debugDescription)" }), draft \(draft() == nil ? "closed" : "open")")
                report("card")
                save(".card.png")
                if let spec = UserDefaults.standard.string(forKey: "snapshotReviewRestyle"), let separator = spec.firstIndex(of: ":") {
                    let keys = [ReviewStyle.colorSchemeKey, ReviewStyle.lineHeightKey]
                    let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
                    UserDefaults.standard.set(String(spec[..<separator]), forKey: keys[0])
                    UserDefaults.standard.set(Double(spec[spec.index(after: separator)...]) ?? 1.3, forKey: keys[1])
                    try? await Task.sleep(for: .milliseconds(800))
                    print("restyled \(spec): text view background \(sides[1].backgroundColor), row height \(sides[1].rowHeight), inline \(sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment }.map { "\($0.frame) \($0.appearance?.name.rawValue ?? "-")" })")
                    report("restyled")
                    save(".restyled.png")
                    for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
                }
                if UserDefaults.standard.bool(forKey: "snapshotReviewDelete") {
                    let button = sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment }.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.toolTip == "Delete Comment" }
                    button?.performClick(nil)
                    try? await Task.sleep(for: .milliseconds(500))
                    let cards = { sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment }.count }
                    print("after card delete: comments \(model.comments.map(\.id)), cards \(cards())")
                    report("deleted")
                    model.comments.append(ReviewComment(id: "list", path: model.selectedDocument?.path ?? "", line: 1, endLine: 1, text: "From the list", snippet: "", compare: model.selectedDocument.flatMap(\.compare)))
                    try? await Task.sleep(for: .milliseconds(500))
                    let added = cards()
                    model.comments.removeAll { $0.id == "list" }
                    try? await Task.sleep(for: .milliseconds(500))
                    print("model append then list delete: cards \(added) → \(cards()), reserved \(sides[1].reserved)")
                }
            }
            if UserDefaults.standard.bool(forKey: "snapshotReviewEditComment"), sides.count == 2 {
                let inline = { sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment } }
                let box = { inline().first(where: \.field.isEditable) }
                let card = { inline().first { !$0.field.isEditable && !$0.isHidden } }
                let state = { (label: String) in
                    print("edit \(label): comments \(model.comments.enumerated().map { "\($0.offset) \($0.element.id) \($0.element.line)-\($0.element.endLine) \($0.element.side) \($0.element.compare.map { "\($0)" } ?? "file") \($0.element.text.debugDescription)" }), box \(box().map { "\($0.frame) \($0.header.stringValue) text \($0.field.string.debugDescription) caret \($0.field.selectedRange().location)+\($0.field.selectedRange().length) of \(($0.field.string as NSString).length), buttons \($0.subviews.compactMap { $0 as? NSButton }.map { "\($0.title) \($0.isEnabled ? "enabled" : "disabled")" })" } ?? "closed"), first responder is box field \(box().map { window.firstResponder === $0.field } ?? false), cards \(inline().filter { !$0.field.isEditable }.map { "\($0.isHidden ? "hidden" : "shown") \($0.frame) \($0.field.string.debugDescription)" }), reserved \(sides[1].reserved)")
                    report("edit-\(label)")
                }
                let type = { (text: String) in
                    for character in text {
                        let keyCode: UInt16 = character == "\r" || character == "\n" ? 36 : character == "\u{1B}" ? 53 : 0
                        let typed = character == "\n" ? "\r" : String(character)
                        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: character == "\n" ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: typed, charactersIgnoringModifiers: typed, isARepeat: false, keyCode: keyCode) else { continue }

                        window.sendEvent(event)
                    }
                }
                let press = { (view: NSView, clicks: Int) in
                    let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                    let event = { (type: NSEvent.EventType) in NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0) }
                    event(.leftMouseUp).map { NSApp.postEvent($0, atStart: false) }
                    event(.leftMouseDown).map(window.sendEvent)
                }
                let doubleClick = {
                    guard let field = card()?.field else { return print("edit: no card to double-click") }

                    press(field, 1)
                    try? await Task.sleep(for: .milliseconds(100))
                    press(field, 2)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                let pencil = {
                    card()?.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Edit Comment" }?.performClick(nil)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                state("before")
                await pencil()
                state("pencil")
                save(".editing.png")
                type(" more\nx")
                try? await Task.sleep(for: .milliseconds(300))
                state("typed")
                type("\u{1B}")
                try? await Task.sleep(for: .milliseconds(300))
                state("esc")
                await doubleClick()
                state("double-click")
                type(" Edited")
                type("\r")
                try? await Task.sleep(for: .milliseconds(500))
                state("saved")
                save(".edited.png")
                if let shown = card(), let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    shown.mouseEntered(with: event)
                    try? await Task.sleep(for: .milliseconds(300))
                    print("edit hover: card buttons \(shown.subviews.compactMap { $0 as? NSButton }.map { "\($0.toolTip ?? "-") \($0.isHidden ? "hidden" : "shown") \($0.frame)" })")
                    save(".card-hover.png")
                    shown.mouseExited(with: event)
                }
                print("edit prompt: \(ReviewComment.prompt(for: model.comments, branch: "b", base: "main").debugDescription)")
                await pencil()
                box()?.field.selectAll(nil)
                box()?.field.delete(nil)
                type("\r")
                try? await Task.sleep(for: .milliseconds(300))
                state("emptied")
                await pencil()
                if let gutter = sides[1].gutter {
                    let y = gutter.convert(sides[1].convert(NSPoint(x: 0, y: sides[1].top(ofRow: sides[1].side?.rows.first ?? 0) + sides[1].rowHeight / 2), to: nil), from: nil).y
                    mouse(gutter, [y, y])
                }
                try? await Task.sleep(for: .milliseconds(300))
                state("gutter over edit")
                type("\u{1B}")
                try? await Task.sleep(for: .milliseconds(300))
                store.closeDiff()
                try? await Task.sleep(for: .milliseconds(500))
                print("edit closed diff: \(describe(model))")
                let row = NSPoint(x: 100, y: (window.contentView?.frame.height ?? 0) - 828)
                for clicks in [1, 2] {
                    let event = { (type: NSEvent.EventType) in NSEvent.mouseEvent(with: type, location: row, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0) }
                    event(.leftMouseUp).map { NSApp.postEvent($0, atStart: false) }
                    event(.leftMouseDown).map(window.sendEvent)
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(2))
                print("edit panel double-click: \(describe(model)), request pending \(model.editingComment != nil)")
                state("panel double-click")
                save(".panel-edit.png")
                type("\u{1B}")
                try? await Task.sleep(for: .milliseconds(300))
                await pencil()
                let first = model.comments.first?.id
                model.comments.removeAll { $0.id == first }
                try? await Task.sleep(for: .milliseconds(500))
                state("deleted while editing")
            }
            let resize = UserDefaults.standard.double(forKey: "snapshotReviewResize")
            if resize > 0 {
                window.setContentSize(NSSize(width: resize, height: 900))
                try? await Task.sleep(for: .seconds(1))
                report("resized")
                save(".resized.png")
            }
            if UserDefaults.standard.bool(forKey: "snapshotReviewSurfaces"), let split = descendantViews(window.contentView ?? NSView()).first(where: { $0.identifier?.rawValue == "terminalSplit" }) as? NSSplitView, let claude = store.tabs.first(where: { $0.id == store.selectedTabID }) {
                let file = model.selectedDocument
                let mounted = { store.tabs.map { tab in tab.terminal.attachedPlatformView.map { [ObjectIdentifier($0), $0.superview.map(ObjectIdentifier.init)] } ?? [] } }
                let windows = { store.tabs.map { $0.terminal.attachedPlatformView?.window === window } }
                let starts = { (try? String(contentsOfFile: NSTemporaryDirectory() + "berth-shell-starts", encoding: .utf8))?.split(separator: "\n").count ?? 0 }
                let processes = ProcessAncestry.descendants()
                let views = mounted()
                let ptyCount = ptys()
                let shellStarts = starts()
                print("surfaces before: window \(Int(window.frame.width)), split x \(Int(split.convert(split.bounds, to: nil).minX))-\(Int(split.convert(split.bounds, to: nil).maxX)), \(split.arrangedSubviews.map { Int($0.frame.width) }), \(store.tabs.count) tabs, descendants \(processes.map(\.pid).sorted()), ptys \(ptyCount), shell starts \(shellStarts)")
                let flipSidebar = {
                    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                    arguments["sidebarPosition"] = UserDefaults.standard.string(forKey: "sidebarPosition") == "right" ? "left" : "right"
                    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                }
                let steps: [(String, () -> Void)] = [
                    ("close diff", { store.closeDiff() }),
                    ("open diff", { file.map(model.open) }),
                    ("hide changes", { AppAction.hideChanges.perform(on: store) }),
                    ("show changes", { AppAction.showChanges.perform(on: store) }),
                    ("select terminal", { store.activate(store.terminals.first.map { SidebarItem.tab($0.id) }) }),
                    ("select claude", { store.activate(.tab(claude.id)) }),
                    ("harbor", { store.isHarborShown = true }),
                    ("leave harbor", { store.isHarborShown = false }),
                    ("flip sidebar", flipSidebar),
                    ("flip back", flipSidebar),
                    ("scroll right side to x 40", { descendantViews(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.last.map { $0.scroll(NSPoint(x: 40, y: $0.visibleRect.minY)) } }),
                    ("live resize after scroll", {
                        window.setContentSize(NSSize(width: window.contentLayoutRect.width - 80, height: window.contentLayoutRect.height))
                        for side in descendantViews(window.contentView ?? NSView()).compactMap({ $0 as? ReviewTextView }) {
                            side.viewWillStartLiveResize()
                            side.viewDidEndLiveResize()
                        }
                    }),
                    ("narrow to 1200", { window.setContentSize(NSSize(width: 1200, height: window.contentLayoutRect.height)) }),
                    ("close diff again", { store.closeDiff() }),
                    ("reopen diff", { file.map(model.open) }),
                    ("close diff once more", { store.closeDiff() }),
                ]
                for (label, step) in steps {
                    step()
                    try? await Task.sleep(for: .seconds(1.5))
                    let now = ProcessAncestry.descendants()
                    print("\(label): sidebar \(UserDefaults.standard.string(forKey: "sidebarPosition") ?? "left"), text clip x \(descendantViews(window.contentView ?? NSView()).compactMap { ($0 as? ReviewTextView)?.enclosingScrollView?.contentView.bounds.minX }), split x \(Int(split.convert(split.bounds, to: nil).minX))-\(Int(split.convert(split.bounds, to: nil).maxX)), panel \(store.showsReviewPanel ? "shown" : "hidden"), harbor \(store.isHarborShown), diff \(store.reviewModel?.selectedDocument?.path ?? "closed"), split \(split.arrangedSubviews.map { "\(Int($0.frame.width))\(store.tabs.first?.terminal.attachedPlatformView?.isDescendant(of: $0) == true ? " terminal" : " diff")\(split.isSubviewCollapsed($0) ? " collapsed" : "")" }), same views \(mounted() == views), in window \(windows()), lost \(processes.subtracting(now).count), new \(now.subtracting(processes).count), ptys \(ptys()), shell starts \(starts())")
                    save(".\(label.replacing(" ", with: "-")).png")
                }
            }
        }
        if let spec = UserDefaults.standard.string(forKey: "snapshotMultiSelect") {
            let order = topSessions.map { SidebarItem.session($0.id) }
            let rows = spec.split(separator: "|").map(String.init)
            let row = { (token: String) in Int(token.trimmingPrefix(/shift|term/)).map { $0 - 1 } ?? -1 }
            for session in rows.filter({ !$0.hasPrefix("term") }).map(row).filter(topSessions.indices.contains).map({ topSessions[$0] }) {
                store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: session.cwd, sessionID: session.id, terminal: $0.terminal) : $0 }
            }
            for token in rows {
                let index = row(token)
                if token.hasPrefix("term"), store.terminals.indices.contains(index) { store.toggleMultiSelection(.tab(store.terminals[index].id)) }
                guard !token.hasPrefix("term"), order.indices.contains(index) else { continue }

                if token == rows.first { store.activate(order[index]) } else if token.hasPrefix("shift") { store.extendMultiSelection(to: order[index], in: order) } else { store.toggleMultiSelection(order[index]) }
            }
            let name = { (item: SidebarItem?) in
                guard let item else { return "none" }

                if case let .tab(id) = item { return store.terminals.firstIndex { $0.id == id }.map { "term\($0 + 1)" } ?? "tab" }
                return order.firstIndex(of: item).map { "row\($0 + 1)" } ?? "other"
            }
            let report = { (label: String) in
                print("\(label): multi-selection \(store.multiSelection.map(name)), selected \(name(store.selection)), tabs \(store.tabs.map { $0.kind == .shell ? name(.tab($0.id)) : $0.sessionID.map { name(.session($0)) } ?? "tab" }), flagged \(order.filter { if case let .session(id) = $0 { store.flaggedIDs.contains(id) } else { false } }.map(name)), pinned \(store.pinnedSessions.map { name(.session($0.id)) })")
                print("  menu \(MultiSelectionMenu.actions(in: store).map(\.title)), palette \([AppAction.archiveCurrentSession, .flagCurrentSession, .unflagCurrentSession].filter { $0.isAvailable(in: store) }.map { $0.title(in: store) })")
            }
            report("selected \(spec)")
            try? await Task.sleep(for: .seconds(2))
            if let image = image(of: window) { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + ".selected.png")) }
            for prefix in ["Unload", "Pin"] {
                MultiSelectionMenu.actions(in: store).first { $0.title.hasPrefix(prefix) }?.perform()
                report("after menu \(prefix)")
            }
            AppAction.flagCurrentSession.perform(on: store)
            report("after palette Flag")
        }
        if showsStats {
            let start = ContinuousClock.now
            let before = footprint()
            while store.searchIndexVersion == 0 || store.searchIndexing != nil { try? await Task.sleep(for: .milliseconds(50)) }
            print("search index: \(store.searchIndex.count) files in \(ContinuousClock.now - start), text \(store.searchIndex.textBytes / 1024) KB, footprint \(before / 1_048_576) → \(footprint() / 1_048_576) MB")
            let activities = store.searchIndex.activities
            let stats = UsageStats(sessions: (store.activeSessions + store.archivedSessions).compactMap { summary in activities[summary.id].map { (summary: summary, activity: $0) } })
            print("stats: projects \(stats.projects), totals \(stats.totals), replies \(activities.values.reduce(0) { $0 + $1.replies.count }), sessions this week \(stats.sessionsThisWeek), prompts this week \(stats.promptsThisWeek), longest \(stats.longestSession.map { "\($0.title) \(Int($0.active / 60)) min" } ?? "-"), most active \(stats.mostActiveProject.map { "\($0.project) \($0.count)" } ?? "-")")
            print("sessions per project: \(stats.sessionsPerProject.map { "\($0.project) \($0.count)" }), busiest cell \(stats.promptsPerHour.max { $0.prompts < $1.prompts }.map { "\($0.weekday)/\($0.hour) \($0.prompts)" } ?? "-")")
        }
        if let query = UserDefaults.standard.string(forKey: "snapshotSearch") {
            Task {
                let start = ContinuousClock.now
                let before = footprint()
                while store.searchIndexVersion == 0 || store.searchIndexing != nil { try? await Task.sleep(for: .milliseconds(50)) }
                print("search index: \(store.searchIndex.count) files in \(ContinuousClock.now - start), text \(store.searchIndex.textBytes / 1024) KB, footprint \(before / 1_048_576) → \(footprint() / 1_048_576) MB")
                let clock = ContinuousClock.now
                let hits = store.searchIndex.search(query, in: store.activeSessions + store.archivedSessions)
                print("search \(query.count) chars: \(hits.count) hits, snippets \(hits.map(\.snippets.count)), \(ContinuousClock.now - clock)")
            }
        }
        try? await Task.sleep(for: .seconds(UserDefaults.standard.string(forKey: "snapshotClaude") == nil && UserDefaults.standard.string(forKey: "snapshotResume") == nil ? 3 : 10))
        try? await Task.sleep(for: .seconds(UserDefaults.standard.integer(forKey: "snapshotHold")))
        if UserDefaults.standard.bool(forKey: "snapshotCloseTabs") {
            let processes = ProcessAncestry.descendants()
            print("before close: \(processes.map(\.pid).sorted())")
            for tab in store.tabs { store.close(tab.id) }
            try? await Task.sleep(for: .seconds(3))
            print("alive after close: \(processes.map(\.pid).filter { kill($0, 0) == 0 }.sorted())")
        }
        if UserDefaults.standard.bool(forKey: "snapshotArchiveTab") {
            for tab in [store.tabs.first { $0.id != store.selectedTabID }, store.tabs.first { $0.id == store.selectedTabID }].compactMap(\.self) {
                weak let view = tab.terminal.attachedPlatformView
                let kind = tab.id == store.selectedTabID ? "selected" : "background"
                if let view { window.makeFirstResponder(view) }
                try? await Task.sleep(for: .seconds(1))
                print("ptys before archive: \(ptys())")
                store.archive(tab.sessionID ?? "")
                try? await Task.sleep(for: .seconds(3))
                print("archived \(kind) tab: view freed \(view == nil), ptys \(ptys())")
            }
        }
        if UserDefaults.standard.bool(forKey: "snapshotDrop") {
            await dropFiles(in: window, store: store)
        }
        if UserDefaults.standard.bool(forKey: "snapshotActivateFocus") {
            for step in ["open tab", "new tab"] {
                store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                store.tabs = store.tabs.map { Tab(id: $0.id, kind: .claude, cwd: $0.cwd, sessionID: nil, terminal: $0.terminal) }
                if step == "open tab" { try? await Task.sleep(for: .seconds(2)) }
                guard let target = store.tabs.last else { continue }

                window.makeFirstResponder(hosting.view)
                print("\(step) before activate: first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
                store.activate(.tab(target.id))
                try? await Task.sleep(for: .seconds(2))
                print("\(step) after activate: first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"), is the activated surface \(window.firstResponder === target.terminal.attachedPlatformView)")
            }
        }
        if let needle = UserDefaults.standard.string(forKey: "snapshotTerminalSearch"), let shell = store.terminals.first {
            let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
            let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
            method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
            method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
            store.activate(.tab(shell.id))
            _ = shell.terminal.paste(text: "printf 'alpha\\nbeta\\nalpha\\n'")
            _ = shell.terminal.sendKey(.enter)
            try? await Task.sleep(for: .seconds(1))
            let press = { (characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) in
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }

                window.sendEvent(event)
            }
            let responder = { store.focusedTerminal?.attachedPlatformView === window.firstResponder ? "terminal surface" : window.firstResponder.map { "\(type(of: $0))" } ?? "nil" }
            AppAction.findInTerminal.perform(on: store)
            try? await Task.sleep(for: .milliseconds(500))
            print("find opened: bar \(store.terminalSearch != nil), first responder \(responder())")
            for character in needle { press(String(character), 0, []) }
            try? await Task.sleep(for: .seconds(1))
            print("typed \(needle.debugDescription): needle \(store.terminalSearch?.needle.debugDescription ?? "-"), total \(store.terminalSearch?.total.map(String.init) ?? "nil"), selected \(store.terminalSearch?.selected.map(String.init) ?? "nil")")
            for (label, flags) in [("return", NSEvent.ModifierFlags()), ("return", []), ("shift-return", .shift)] {
                press("\r", 36, flags)
                try? await Task.sleep(for: .milliseconds(500))
                print("after \(label): total \(store.terminalSearch?.total.map(String.init) ?? "nil"), selected \(store.terminalSearch?.selected.map(String.init) ?? "nil"), bar \(store.terminalSearch != nil), first responder \(responder())")
            }
            if let image = image(of: window) { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + ".find.png")) }
            AppAction.findInTerminal.perform(on: store)
            try? await Task.sleep(for: .milliseconds(500))
            print("find again: field selection \((window.firstResponder as? NSTextView).map { NSStringFromRange($0.selectedRange()) } ?? "-") of \(store.terminalSearch?.needle.count ?? 0) characters")
            press("\u{7F}", 51, [])
            try? await Task.sleep(for: .milliseconds(500))
            print("cleared: needle \(store.terminalSearch?.needle.debugDescription ?? "-"), total \(store.terminalSearch?.total.map(String.init) ?? "nil"), selected \(store.terminalSearch?.selected.map(String.init) ?? "nil")")
            if let image = image(of: window) { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + ".cleared.png")) }
            press("\u{1B}", 53, [])
            try? await Task.sleep(for: .milliseconds(500))
            print("after esc: bar \(store.terminalSearch == nil ? "closed" : "open"), first responder \(responder())")
        }
        if let keys = UserDefaults.standard.string(forKey: "snapshotKeys") {
            SettingsSnapshot.keepWindowsOffScreen()
            window.identifier = NSUserInterfaceItemIdentifier("main-snapshot")
            let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
            let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
            method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
            method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
            if store.reviewModel?.selectedDocument?.path == nil { window.makeFirstResponder(store.focusedTerminal?.attachedPlatformView ?? window.contentView) }
            func descendantViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantViews) }
            let state = {
                let focused = store.tabs.firstIndex { $0.terminal.attachedPlatformView === window.firstResponder }.map { "#\($0)" } ?? window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
                let split = (descendantViews(window.contentView ?? NSView()).first { $0.identifier?.rawValue == "terminalSplit" } as? NSSplitView).map { split in split.arrangedSubviews.map { "\(Int($0.frame.width))\(store.tabs.first?.terminal.attachedPlatformView?.isDescendant(of: $0) == true ? " terminal" : " diff")\(split.isSubviewCollapsed($0) ? " collapsed" : "")" } } ?? []
                let layout = "layout \(UserDefaults.standard.string(forKey: ReviewDiffLayout.key) ?? "unset"), shown \((descendantViews(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.last?.unifiedOriginal).map { _ in "unified" } ?? "side by side"), offered \([AppAction.showSideBySide, .showInline].filter { $0.isAvailable(in: store) }.map(\.title))"
                let review = store.reviewModel.map { "review \($0.folder) \($0.changes.map { "\($0.branch) uncommitted \($0.uncommitted.map { "\($0.path) +\($0.additions ?? 0) -\($0.deletions ?? 0)" }) committed \($0.committed.map(\.path))" } ?? "not loaded"), loads \($0.loadCount)\($0.error.map { ", error \($0)" } ?? "")\($0.movedFolder.map { ", movedFolder \($0)" } ?? "")" } ?? "no review"
                return "split \(split), \(layout), \(review), tabs \(store.tabs.enumerated().map { "\($1.kind)#\($0)" }), selected \(store.tabs.firstIndex { $0.id == store.selectedTabID }.map { "#\($0)" } ?? "none"), focused \(focused), terminals \(store.terminals.count) in \(store.terminals.map { URL(filePath: $0.folder).lastPathComponent }), panel \(store.showsReviewPanel), diff \(store.reviewModel.map(describe) ?? "closed"), expanded folders \(store.reviewModel.map { $0.expandedFolders.sorted() } ?? []), collapsed change folders \(store.reviewModel.map { $0.collapsedChangeFolders.map { "\($0.compare.map { "\($0) " } ?? "")\($0.path)" }.sorted() } ?? []), unsaved \(store.reviewModels.values.contains(where: \.hasUnsavedEdits)), review text focused \(store.isReviewTextFocused), find \(store.terminalSearch.map { "open, total \($0.total.map(String.init) ?? "nil"), selected \($0.selected.map(String.init) ?? "nil")" } ?? "closed")" + ((window.firstResponder as? ReviewTextView).map { textView in ", text \(textView.string.prefix(16).debugDescription) (\(textView.string.count) characters), can undo \(textView.undoManager?.canUndo == true), can redo \(textView.undoManager?.canRedo == true), carets \(textView.carets.ranges.map { "\(textView.position(ofOffset: $0.location).line + 1):\(textView.position(ofOffset: $0.location).character + 1)+\($0.length)" }) primary #\(textView.carets.primary), layoutManager requests \(textView.layoutManagerRequests), TextKit 2 \(textView.textLayoutManager != nil)" } ?? "") + ", occurrences \(descendantViews(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.map { "\($0.occurrences.count) on \($0.occurrenceRows.count) rows" })" + ", right top line \(descendantViews(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.last.flatMap { view in view.enclosingScrollView.flatMap { view.line(atY: $0.contentView.bounds.minY + 1) } }.map { $0 + 1 } ?? 0)" + ((window.firstResponder as? NSTextView).flatMap { $0 is ReviewTextView ? nil : ", find field \($0.string.debugDescription)" } ?? "")
            }
            let savedLayout = UserDefaults.standard.object(forKey: ReviewDiffLayout.key)
            let savedPasteboard = NSPasteboard.general.string(forType: .string)
            print("start: \(state())")
            print("key window is snapshot: \(NSApp.keyWindow === window), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { note in
                print("  menu action: \((note.userInfo?["MenuItem"] as? NSMenuItem)?.title ?? "?")")
            }
            let keyCodes: [String: UInt16] = ["r": 15, "x": 7, "z": 6, "a": 0, "s": 1, "f": 3, "c": 8, "v": 9, "q": 12, "w": 13, "t": 17, "1": 18, "2": 19, "3": 20, "9": 25, "g": 5, "esc": 53, "]": 30, "[": 33, "enter": 36, "j": 38, "k": 40, ",": 43, "n": 45, "tab": 48, "=": 24, "-": 27, "d": 2, "l": 37, "u": 32, "i": 34, "up": 126, "down": 125, "left": 123, "right": 124, "delete": 51, "f2": 120]
            let flagNames: [String: NSEvent.ModifierFlags] = ["cmd": .command, "shift": .shift, "alt": .option, "ctrl": .control]
            let gap = UserDefaults.standard.string(forKey: "snapshotKeysGap").flatMap(Int.init) ?? 400
            for spec in keys.split(separator: " ").map(String.init) {
                if spec.hasPrefix("browse"), let index = Int(spec.dropFirst(6)), store.sidebarOrderedTabs.indices.contains(index) {
                    store.selectedTabID = store.sidebarOrderedTabs[index].id
                    print("\(spec) (sets the selection like ↑/↓ in the sidebar):\n  \(state())")
                    continue
                }
                if spec == "terminal" {
                    window.makeFirstResponder(store.focusedTerminal?.attachedPlatformView)
                    try? await Task.sleep(for: .milliseconds(gap))
                    print("terminal (focuses the selected tab's terminal):\n  \(state())")
                    continue
                }
                if spec == "exit" {
                    _ = store.focusedTerminal?.paste(text: "exit")
                    _ = store.focusedTerminal?.sendKey(.enter)
                    try? await Task.sleep(for: .seconds(2))
                    print("exit (typed into the selected terminal):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("click:") || spec.hasPrefix("dblclick:") {
                    let numbers = spec.split(separator: ":").last?.split(separator: ",").compactMap { Double($0) } ?? []
                    let location = NSPoint(x: numbers.first ?? 0, y: (window.contentView?.frame.height ?? 0) - (numbers.last ?? 0))
                    for count in spec.hasPrefix("dbl") ? [1, 2] : [1] {
                        let event = { (type: NSEvent.EventType) in NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) }
                        // A control's mouse-down tracking loop waits for the mouse-up, so it is queued first.
                        event(.leftMouseUp).map { NSApp.postEvent($0, atStart: false) }
                        event(.leftMouseDown).map(window.sendEvent)
                    }
                    try? await Task.sleep(for: .seconds(1))
                    print("\(spec) (sends a real \(spec.hasPrefix("dbl") ? "double-click" : "click") at that point, top-left origin):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("altclick:") || spec.hasPrefix("altdrag:"), let right = descendantViews(window.contentView ?? NSView()).compactMap({ $0 as? ReviewTextView }).last {
                    let points = spec.split(separator: ":", maxSplits: 1).last?.split(separator: "-").compactMap { position -> NSPoint? in
                        if position.hasPrefix("row"), let row = Int(position.dropFirst(3)) { return right.convert(NSPoint(x: 60, y: right.top(ofRow: row) + right.rowHeight / 2), to: nil) }
                        let numbers = position.split(separator: ":").compactMap { Int($0) }
                        guard numbers.count == 2, let rect = right.segments(of: NSRange(location: right.offset(of: LanguageServerPosition(line: numbers[0] - 1, character: numbers[1] - 1)), length: 0)).first?.rect else { return nil }

                        return right.convert(NSPoint(x: rect.minX + 1, y: rect.midY), to: nil)
                    } ?? []
                    let flags: NSEvent.ModifierFlags = spec.hasPrefix("altdrag:") ? [.option, .shift] : .option
                    let event = { (type: NSEvent.EventType, location: NSPoint) in NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) }
                    if let first = points.first, let last = points.last {
                        event(.leftMouseDown, first).map(right.mouseDown)
                        if points.count > 1 { event(.leftMouseDragged, last).map(right.mouseDragged) }
                        event(.leftMouseUp, last).map(right.mouseUp)
                    }
                    try? await Task.sleep(for: .milliseconds(gap))
                    print("\(spec) (sends the right side ⌥ mouse events at that line:column, ⇧⌥ from the first to the second for altdrag):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("git:"), let folder = store.reviewModel?.folder {
                    let git = Process()
                    git.executableURL = URL(filePath: "/usr/bin/git")
                    git.arguments = ["-C", folder] + spec.dropFirst(4).split(separator: ",").map(String.init)
                    try? git.run()
                    git.waitUntilExit()
                    try? await Task.sleep(for: .seconds(2))
                    print("\(spec) (runs git with those comma-separated arguments in the review folder, waits 2 s):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("relocate:"), let index = store.tabs.firstIndex(where: { $0.id == store.selectedTabID }) {
                    store.tabs[index].cwd = String(spec.dropFirst(9))
                    try? await Task.sleep(for: .seconds(2))
                    print("\(spec) (sets the selected tab's folder like a scan after /cd, waits 2 s):\n  \(state())")
                    continue
                }
                if spec == "uncomment" {
                    store.reviewModel?.comments = []
                    try? await Task.sleep(for: .seconds(2))
                    print("\(spec) (deletes the review model's comments, waits 2 s):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("layout:") {
                    UserDefaults.standard.set(spec == "layout:auto" ? nil : String(spec.dropFirst(7)), forKey: ReviewDiffLayout.key)
                    try? await Task.sleep(for: .seconds(1))
                    print("\(spec) (writes reviewDiffLayout, restored after the run):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("width:"), let width = Double(spec.dropFirst(6)) {
                    window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
                    try? await Task.sleep(for: .seconds(1))
                    print("\(spec) (sets the window width):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("select:"), let right = descendantViews(window.contentView ?? NSView()).compactMap({ $0 as? ReviewTextView }).last {
                    let range = (right.string as NSString).range(of: String(spec.dropFirst(7)).replacing("\\n", with: "\n").replacing("\\s", with: " "))
                    let before = right.occurrences
                    window.makeFirstResponder(right)
                    right.setSelectedRange(range.location == NSNotFound ? NSRange(location: 0, length: 0) : range)
                    right.scrollRangeToVisible(right.selectedRange())
                    let start = Date.now
                    while right.occurrences == before, Date.now.timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(10)) }
                    let elapsed = Int(Date.now.timeIntervalSince(start) * 1000)
                    try? await Task.sleep(for: .milliseconds(300))
                    print("\(spec) (selects that text's first match on the right side, occurrences after \(elapsed) ms):\n  \(state())")
                    continue
                }
                if spec.hasPrefix("shot:") {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let image = image(of: window) { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + ".\(spec.dropFirst(5)).png")) }
                    print("\(spec) (saves <out>.\(spec.dropFirst(5)).png):\n  \(state())")
                    continue
                }
                if let model = store.reviewModel, ["refresh", "keep", "save", "back", "forward", "reveal"].contains(spec) || spec.hasPrefix("file") || spec.hasPrefix("open:") || spec.hasPrefix("dbl:") {
                    let target = spec.split(separator: ":", maxSplits: 2).map(String.init)
                    let document = target.count == 3 ? ["u": ReviewDocument(path: target[2], compare: .uncommitted), "c": ReviewDocument(path: target[2], compare: .committed)][target[1]] ?? model.workingDocument(target[2]) : nil
                    if spec == "refresh" { await store.refreshReview() }
                    if spec == "keep" { model.selectedTabID.map(model.keep) }
                    if spec == "save", let path = model.selectedDocument?.path, let draft = model.drafts[path] { model.save(draft, to: path) }
                    if spec == "back" || spec == "forward" { model.go(by: spec == "back" ? -1 : 1) }
                    if spec == "reveal" { model.filesReveal = model.selectedDocument?.path }
                    if spec.hasPrefix("file"), let index = Int(spec.dropFirst(4)), let file = model.changes.map({ $0.uncommitted.map { ReviewDocument(path: $0.path, compare: .uncommitted) } + $0.committed.map { ReviewDocument(path: $0.path, compare: .committed) } })?.dropFirst(index).first { model.open(file) }
                    if let document {
                        model.open(document)
                        if target[0] == "dbl" { model.selectedTabID.map(model.keep) }
                    }
                    try? await Task.sleep(for: .seconds(1))
                    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                    let right = descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.last
                    if let right { window.makeFirstResponder(right) }
                    print("\(spec) (\(target.count == 3 ? "\(target[0] == "dbl" ? "double-clicks" : "clicks") that row" : spec == "keep" ? "double-clicks the current tab" : spec == "refresh" ? "reloads Review" : Int(spec.dropFirst(4)) != nil ? "clicks that Changes row" : spec), then focuses the diff's right side): right side editable \(right?.isEditable == true), left shown \(right?.unifiedOriginal == nil), the path's editor \(right.map { right in model.editors.values.contains { $0 === right } } ?? false), language \(right?.onDefinition != nil)\n  \(state())")
                    continue
                }
                let parts = spec.split(separator: "+").map(String.init)
                guard let key = parts.last, let keyCode = keyCodes[key] else { continue }

                let flags = NSEvent.ModifierFlags(parts.dropLast().compactMap { flagNames[$0] })
                let characters = ["enter": "\r", "tab": "\t", "esc": "\u{1B}", "up": "\u{F700}", "down": "\u{F701}", "left": "\u{F702}", "right": "\u{F703}", "delete": "\u{7F}"][key] ?? key
                print("\(spec):")
                // Only a synthesized plain key sent to the window types (arrows with ⌃⌥ take the CGEvent path so the key monitor sees them); only a CGEvent-backed chord (51 is its private window number field) matches ⇧⌘Z.
                if flags.isEmpty || ["up", "down", "left", "right"].contains(key) && !flags.contains(.command) && !flags.isSuperset(of: [.control, .option]), let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
                    window.sendEvent(event)
                } else if let source = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) {
                    source.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
                    source.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
                    NSEvent(cgEvent: source).map(NSApp.sendEvent)
                }
                try? await Task.sleep(for: .milliseconds(gap))
                let others = NSApp.windows.filter { $0 !== window && $0.isVisible }
                print("  launcher \(String(describing: store.launcherMode)), \(state()), grouping \(store.groupingMode), windows \(others.map { $0.identifier?.rawValue ?? $0.title })")
                others.forEach { $0.close() }
                store.launcherMode = nil
                try? await Task.sleep(for: .milliseconds(100))
            }
            NotificationCenter.default.removeObserver(observer)
            UserDefaults.standard.set(savedLayout, forKey: ReviewDiffLayout.key)
            if let savedPasteboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedPasteboard, forType: .string)
            }
        }
        if let keys = launcherKeys {
            let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
            let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
            method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
            method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
            window.identifier = NSUserInterfaceItemIdentifier("main-snapshot")
            store.launcherMode = .newSession
            try? await Task.sleep(for: .seconds(1))
            print("launcher first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            let special: [String: (keyCode: UInt16, characters: String)] = ["down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "enter": (36, "\r"), "alt-enter": (36, "\r"), "tab": (48, "\t")]
            let letters: [Character: UInt16] = ["h": 4, "u": 32, "b": 11, "x": 7, "i": 34, "-": 27, "r": 15, "o": 31, "n": 45, "d": 2, "#": 20]
            for spec in keys.split(separator: " ").map(String.init) {
                let strokes = special[spec].map { [$0] } ?? spec.compactMap { character in letters[character].map { (keyCode: $0, characters: String(character)) } }
                for stroke in strokes {
                    let flags: NSEvent.ModifierFlags = spec == "alt-enter" ? .option : ["down", "up"].contains(spec) ? [.function, .numericPad] : []
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: stroke.characters, charactersIgnoringModifiers: stroke.characters, isARepeat: false, keyCode: stroke.keyCode) else { continue }

                    window.sendEvent(event)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                print("\(spec): launcher \(String(describing: store.launcherMode))")
            }
            print("openClaude calls: \(store.probeOpenedClaude.count) \(store.probeOpenedClaude.map { "\(URL(filePath: $0.cwd).lastPathComponent) \($0.start)" })")
            print("opened URLs: \(store.probeOpenedURLs.map(\.absoluteString))")
        }
        let tab = store.tabs.first { $0.id == store.selectedTabID }
        window.title = showsStats ? "Stats" : store.isHarborShown ? "Harbor" : tab.map { $0.title(terminalTitle: $0.terminal.title, sessionTitle: store.sessionTitle(of: $0)) } ?? "Berth"
        try? await Task.sleep(for: .milliseconds(500))
        let items = window.toolbar?.items.map { "\($0.itemIdentifier.rawValue) label=\($0.label) tip=\($0.toolTip ?? "")" } ?? []
        print("window title: \(window.title) | subtitle: \(window.subtitle)")
        print("toolbar items (\(items.count)):\n" + items.joined(separator: "\n"))
        let menus = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu) + (window.toolbar?.items ?? []).compactMap { ($0 as? NSMenuToolbarItem)?.menu }
        for menu in menus where menu.items.contains(where: { $0.title.hasPrefix("Group By") || $0.title.hasPrefix("New ") }) {
            print("menu \(menu.title):")
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items + menu.items.compactMap(\.submenu).flatMap(\.items) where !item.isSeparatorItem {
                print("  \(item.state == .on ? "✓" : " ") \(item.title) \(item.keyEquivalentModifierMask.contains(.control) ? "⌃" : "")\(item.keyEquivalent)")
            }
        }
        print("review panel \(store.showsReviewPanel ? "shown" : "hidden"), diff \(store.reviewModel.map(describe) ?? "closed")")
        print("shell starts: \((try? String(contentsOfFile: NSTemporaryDirectory() + "berth-shell-starts", encoding: .utf8))?.split(separator: "\n").count ?? 0)")
        for tab in store.tabs { print("tab \(tab.kind) cwd=\(tab.cwd) session=\(tab.sessionID ?? "-") pwd=\(tab.terminal.workingDirectory ?? "-") title=\(tab.terminal.title)") }
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { fail("window is on screen") }
        guard let image = image(of: window) else { fail("window capture failed: number \(window.windowNumber) visible \(window.isVisible) frame \(window.frame)") }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: output)) != nil
        else { fail("could not write \(output.path)") }

        ProcessAncestry.hangUpDescendants()
        exit(0)
        #endif
    }

    #if DEBUG
    private static func dropFiles(in window: NSWindow, store: Store) async {
        let folder = URL(filePath: NSTemporaryDirectory()).appending(path: "berth-drop")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [folder.appending(path: "plain.png"), folder.appending(path: "it's a \"quoted\" (copy).png")]
        for file in files { FileManager.default.createFile(atPath: file.path, contents: Data()) }
        let names = ["tab-1", "tab-2", "shell-1", "shell-2"]
        for name in names { store.openShell(cwd: folder.path, command: "/bin/sh -c 'stty -echo; cat > \(folder.path)/\(name)'") }
        store.tabs = store.tabs.enumerated().map { $0 < 2 ? Tab(id: $1.id, kind: .claude, cwd: $1.cwd, sessionID: nil, terminal: $1.terminal) : $1 }
        try? await Task.sleep(for: .seconds(2))
        let terminals = store.tabs.map(\.terminal)
        for index in [0, 2, 1] {
            store.selectedTabID = store.tabs[index].id
            try? await Task.sleep(for: .seconds(1))
            let label = "\(names[index]) selected"
            guard let view = terminals[index].attachedPlatformView, let frameView = window.contentView?.superview else { continue }

            for (kind, files) in [("files", files), ("group", [])] {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("berth-drop-\(UUID().uuidString)"))
                pasteboard.clearContents()
                if files.isEmpty { pasteboard.setData(Data("{}".utf8), forType: NSPasteboard.PasteboardType("dev.gustaf.berth.group")) } else { pasteboard.writeObjects(files.map { $0 as NSURL }) }
                var location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let info = FakeDrag(pasteboard: pasteboard, location: location, window: window)
                // NSWindow's own draggingEntered: rejects a synthesized NSDraggingInfo, so this calls the destination lookup it uses.
                typealias DragHitTest = @convention(c) (NSView, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
                let dragHitTest = Selector(("_hitTest:dragTypes:"))
                let destination = unsafeBitCast(frameView.method(for: dragHitTest), to: DragHitTest.self)(frameView, dragHitTest, &location, NSSet(array: (pasteboard.types ?? []).map(\.rawValue)))
                let owner = terminals.firstIndex { $0.attachedPlatformView === destination }.map { names[$0] } ?? destination.map { "\(type(of: $0))" } ?? "none"
                let operation = destination?.draggingEntered(info) ?? []
                let performed = !operation.isEmpty && destination?.performDragOperation(info) == true
                print("drop \(kind) on \(label): destination \(owner), operation \(operation.rawValue), performed \(performed)")
                pasteboard.releaseGlobally()
            }
        }
        for terminal in terminals { _ = terminal.sendKey(.enter) }
        try? await Task.sleep(for: .seconds(1))
        for name in names { print("received \(name): \((try? String(contentsOf: folder.appending(path: name), encoding: .utf8)) ?? "-")") }
    }
    #endif

    static func describe(_ model: ReviewModel) -> String {
        guard !model.tabs.isEmpty else { return "closed" }

        return "tabs " + model.tabs.map { tab in
            "\(tab.id == model.selectedTabID ? "[" : "")\(tab.document.path)\(tab.document.compare.map { " \($0)" } ?? " file") \(tab.isPreview ? "preview" : "kept") \(tab.index + 1)/\(tab.history.count)\(tab.id == model.selectedTabID ? "]" : "")"
        }.joined(separator: ", ")
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Int(info.phys_footprint)
    }

    private static func ptys() -> Int {
        let lsof = Process()
        let pipe = Pipe()
        lsof.executableURL = URL(filePath: "/usr/sbin/lsof")
        lsof.arguments = ["-p", "\(getpid())"]
        lsof.standardOutput = pipe
        try? lsof.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").count(where: { $0.contains("/dev/ptmx") })
    }

    private static func fail(_ message: String) -> Never {
        ProcessAncestry.hangUpDescendants()
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(1)
    }

    // cacheDisplay skips Liquid Glass and Metal; CGWindowListCreateImage is SDK-obsoleted but still exported and captures own windows without Screen Recording.
    static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }

        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}

private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }
}

#if DEBUG
private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = [.copy, .generic, .link]
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation = NSDraggingFormation.default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight = NSSpringLoadingHighlight.none

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }

    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(options _: NSDraggingItemEnumerationOptions = [], for _: NSView?, classes _: [AnyClass], searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:], using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
#endif
