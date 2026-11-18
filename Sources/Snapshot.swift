import BerthCore
import AppKit
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
        return [(session, PullRequestState(rawValue: state.capitalized).map { PullRequest(number: 4821, url: URL(string: "https://github.com/acme/billing/pull/4821")!, title: "Reconcile ledger entries against settlement exports and flag every mismatch", state: $0) })]
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

    static let fixtureSessions = !pullRequestFixtures.isEmpty ? pullRequestFixtures.map(\.session) : launcherKeys != nil ? hubFolders : nil
    private static let fixtureRepository = UserDefaults.standard.string(forKey: "snapshotReviewRepository") ?? "acme/billing"
    static let fixtureRepositories = Dictionary(pullRequestFixtures.map { (RepositoryRoot.resolve($0.session.cwd), String?.some(fixtureRepository)) }) { first, _ in first }
    static let fixturePullRequests = Dictionary(pullRequestFixtures.compactMap { item in item.session.branch.map { (PullRequestBranch(repository: fixtureRepository, branch: $0), item.pullRequest) } }) { first, _ in first }
    #else
    static let fixtureSessions: [SessionSummary]? = nil
    static let launcherKeys: String? = nil
    static let fixtureRepositories: [String: String?] = [:]
    static let fixturePullRequests: [PullRequestBranch: PullRequest?] = [:]
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
    static let launcherQuery = UserDefaults.standard.string(forKey: "snapshotLauncher") ?? UserDefaults.standard.string(forKey: "snapshotSearch") ?? UserDefaults.standard.string(forKey: "snapshotPalette") ?? ""
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
        if UserDefaults.standard.bool(forKey: "snapshotUnread") {
            for session in topSessions.enumerated().filter({ [1, 3].contains($0.offset) }).map(\.element) { store.markUnread(session.id) }
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
        if let cwd = UserDefaults.standard.string(forKey: "snapshotClaude") {
            store.openClaude(cwd: cwd, checkout: .main)
        }
        if let version = UserDefaults.standard.string(forKey: "snapshotRestartBanner") {
            store.updater.showPendingRestart(version: version, deadline: .now + 18)
        }
        if UserDefaults.standard.string(forKey: "snapshotLauncher") != nil { store.launcherMode = .newSession }
        if UserDefaults.standard.string(forKey: "snapshotSearch") != nil { store.launcherMode = .search }
        if UserDefaults.standard.string(forKey: "snapshotPalette") != nil { store.launcherMode = .palette }
        let editedGroup = UserDefaults.standard.string(forKey: "snapshotEditGroup").map { name in
            store.customGroups.first { $0.name == name } ?? CustomGroup(name: "", rules: [])
        }
        let servers = LanguageServerEntry.configured(UserDefaults.standard.string(forKey: LanguageServerEntry.storageKey))
        let editedServer = UserDefaults.standard.string(forKey: "snapshotEditServer").map { id in servers.first { $0.id == id } ?? LanguageServerEntry(name: "", command: "") }
        let showsStats = UserDefaults.standard.bool(forKey: "snapshotStats")
        let root = editedGroup.map { AnyView(GroupEditor(group: $0).environment(\.ghosttyTheme, store.theme).preferredColorScheme(store.theme.isDark ? .dark : .light)) }
            ?? editedServer.map { AnyView(LanguageServerEditor(server: $0, servers: .constant(servers)).preferredColorScheme(store.theme.isDark ? .dark : .light)) } ?? AnyView(showsStats ? AnyView(StatsView()) : AnyView(ContentView()))
        let hosting = NSHostingController(rootView: root.environment(store))
        hosting.sceneBridgingOptions = .all
        let window = UnconstrainedWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(editedGroup != nil || editedServer != nil ? hosting.view.fittingSize : showsStats ? NSSize(width: 960, height: 800) : reviewFolder != nil ? NSSize(width: UserDefaults.standard.object(forKey: "snapshotReviewWidth") == nil ? 1600 : UserDefaults.standard.double(forKey: "snapshotReviewWidth"), height: 900) : NSSize(width: 1200, height: 760))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
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
            try? await Task.sleep(for: .seconds(1))
            print("review \(model.changes.map { "\($0.branch) → \($0.base ?? "-"), fetch error \($0.fetchError ?? "-")" } ?? "error \(model.error ?? "timed out")")")
            print("review card \(model.status.map { "base \(model.changes?.base ?? "-"), default branch \(model.changes?.isDefaultBranch == true), ahead \($0.ahead), behind \($0.behind), upstream \($0.upstream.map { "\($0.name) +\($0.ahead) -\($0.behind)" } ?? "-"), commits \($0.commits.map { "\($0.sha) \($0.isPushed ? "pushed" : "unpushed")" })" } ?? "none"), pull request details \(model.pullRequestDetails)")
            for (section, files) in [("uncommitted", model.changes?.uncommitted ?? []), ("committed", model.changes?.committed ?? [])] {
                for file in files { print("  \(section) \(file.status.rawValue) \(file.path) +\(file.additions.map(String.init) ?? "?") -\(file.deletions.map(String.init) ?? "?")") }
            }
            print("review files tree \(model.tree.map { $0.children == nil ? $0.name : "\($0.name)/ (\($0.children?.count ?? 0))" })")
            print("review selected \(describe(model)), contents loaded \(model.selectedDocument.flatMap { model.contents[$0] } != nil), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let sides = descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }
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
                for (index, side) in sides.enumerated() {
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
                let shifted = unchanged.filter { pair in rows[0][pair.0].flatMap { left in rows[1][pair.1].map { left != $0 } } ?? false }.count
                let arithmetic = unchanged.filter { pair in rows[1][pair.1].map { $0 != sides[1].top(ofRow: (sides[1].side ?? diff.modified).rows[pair.1]) } ?? false }.count
                print("\(label) \(sides[1].unifiedOriginal == nil ? "side by side" : "unified, width \(sides[1].frame.width) for \(sides[1].minimumWidth), text is the file \(sides[1].string == model.drafts[model.selectedDocument?.path ?? ""] ?? model.selectedDocument.flatMap { model.contents[$0]?.modified }.flatMap { if case let .text(text) = $0 { text } else { nil } } ?? "")"), height \(sides[1].frame.height) for top(ofRow: rowCount) \(sides[1].top(ofRow: sides[1].side?.rowCount ?? 0)), pane \(sides[1].enclosingScrollView?.superview?.frame.width ?? -1) hunks \(diff.hunks.count), checked \(checks.count), misaligned \(checks.filter { $0.1 != $0.2 }.count), unchanged pairs misaligned \(shifted), off top(ofRow:) \(arithmetic): " + checks.prefix(6).map { "\($0.0.originalLines)/\($0.0.modifiedLines) next row y \($0.1)/\($0.2)" }.joined(separator: ", "))
            }
            report("review")
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
                    if type == .mouseMoved { textView.mouseMoved(with: event) } else { textView.mouseDown(with: event) }
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
                while ContinuousClock.now - clock < .seconds(120), right()?.diagnostics.isEmpty != false { try? await Task.sleep(for: .milliseconds(250)) }
                let waited = ContinuousClock.now - clock
                var settled = (diagnostics: right()?.diagnostics ?? [], at: ContinuousClock.now)
                while ContinuousClock.now - settled.at < .seconds(3), ContinuousClock.now - clock < .seconds(150) {
                    try? await Task.sleep(for: .milliseconds(250))
                    if let shown = right()?.diagnostics, shown != settled.diagnostics { settled = (shown, .now) }
                }
                if let textView = right(), let gutter = textView.gutter {
                    print("diagnostics shown after \(waited): " + textView.diagnostics.map { "\($0.range.start.line + 1):\($0.range.start.character + 1)-\($0.range.end.line + 1):\($0.range.end.character + 1) \($0.severity.map { "\($0)" } ?? "-") \($0.message.debugDescription) (\($0.source ?? "-"))" }.joined(separator: "; "))
                    if let first = textView.diagnostics.first, let segment = textView.segments(of: NSRange(location: textView.offset(of: first.range.start), length: 1)).first {
                        let middle = NSPoint(x: segment.rect.midX, y: segment.rect.midY)
                        let mark = gutter.convert(middle, from: textView)
                        print("diagnostic tooltips: text \(textView.view(textView, stringForToolTip: 0, point: middle, userData: nil).debugDescription), gutter \(gutter.view(gutter, stringForToolTip: 0, point: NSPoint(x: 7, y: mark.y), userData: nil).debugDescription)")
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
                if let spec = UserDefaults.standard.string(forKey: "snapshotReviewHover"), let textView = right(), let target = point(textView, spec) {
                    let requests = textView.layoutManagerRequests
                    let card = { textView.subviews.first { $0.subviews.first is NSTextField } }
                    let started = ContinuousClock.now
                    while ContinuousClock.now - started < .seconds(60), card() == nil {
                        mouse(textView, .mouseMoved, NSPoint(x: textView.bounds.maxX - 2, y: target.y), [])
                        mouse(textView, .mouseMoved, target, [])
                        try? await Task.sleep(for: .seconds(2))
                    }
                    print("hover \(spec) after \(ContinuousClock.now - started): \((card()?.subviews.first as? NSTextField)?.stringValue.debugDescription ?? "no card"), card \(card().map { "\($0.frame), label \($0.subviews.first?.frame ?? .zero)" } ?? "-"), visible width \(textView.visibleRect.width), layoutManager requests \(requests) → \(textView.layoutManagerRequests), TextKit 2 \(textView.textLayoutManager != nil)")
                    if let shown = card() { crop(".hover.png", textView, shown.frame.union(NSRect(x: target.x - 60, y: target.y - 20, width: 120, height: 20)).insetBy(dx: -16, dy: -16)) }
                    mouse(textView, .mouseMoved, NSPoint(x: textView.bounds.maxX - 2, y: target.y), [])
                    print("hover after moving away: card \(card() == nil ? "dismissed" : "shown")")
                }
                for spec in (UserDefaults.standard.string(forKey: "snapshotReviewDefinition") ?? "").split(separator: "|").map(String.init) {
                    if model.selectedDocument != file {
                        model.open(file)
                        try? await Task.sleep(for: .seconds(2))
                    }
                    guard let textView = right(), let target = point(textView, spec) else { continue }
                    let requests = textView.layoutManagerRequests
                    let before = textView.selectedRange()
                    mouse(textView, .mouseMoved, target, .command)
                    try? await Task.sleep(for: .milliseconds(300))
                    crop(".link-\(spec.replacingOccurrences(of: ":", with: "-")).png", textView, NSRect(x: target.x - 120, y: target.y - 20, width: 240, height: 40))
                    mouse(textView, .leftMouseDown, target, .command)
                    let started = ContinuousClock.now
                    while ContinuousClock.now - started < .seconds(20), model.reveal != nil || (model.selectedDocument == file && right()?.selectedRange() == before) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .seconds(1))
                    guard model.selectedDocument != file || right()?.selectedRange() != before, let landed = right() else {
                        print("definition \(spec): no landing after \(ContinuousClock.now - started) (outside the repository or no answer), selected \(model.selectedDocument?.path ?? "-")")
                        continue
                    }
                    let selection = landed.selectedRange()
                    let position = landed.position(ofOffset: selection.location)
                    print("definition \(spec): landed in \(describe(model)) at \(position.line + 1):\(position.character + 1) selecting \((landed.string as NSString).substring(with: selection).debugDescription), clip y left/right \(descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.map { "\($0.enclosingScrollView?.contentView.bounds.minY ?? -1)" }), first responder is right \(window.firstResponder === landed), layoutManager requests \(requests) → \(landed.layoutManagerRequests), TextKit 2 \(landed.textLayoutManager != nil)")
                    save(".definition-\(spec.replacingOccurrences(of: ":", with: "-")).png")
                    let landedDocument = model.selectedDocument
                    await model.load()
                    try? await Task.sleep(for: .seconds(1))
                    print("definition \(spec): after Refresh still showing \(landedDocument?.path ?? "-") \(model.selectedDocument == landedDocument && landedDocument.flatMap { model.contents[$0] } != nil), \(describe(model))")
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
                let draft = { sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment }.first { $0.field.isEditable } }
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
                    save(".\(label.replacingOccurrences(of: " ", with: "-")).png")
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
                weak var view = tab.terminal.attachedPlatformView
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
                return "split \(split), tabs \(store.tabs.enumerated().map { "\($1.kind)#\($0)" }), selected \(store.tabs.firstIndex { $0.id == store.selectedTabID }.map { "#\($0)" } ?? "none"), focused \(focused), terminals \(store.terminals.count) in \(store.terminals.map { URL(filePath: $0.folder).lastPathComponent }), panel \(store.showsReviewPanel), diff \(store.reviewModel.map(describe) ?? "closed"), unsaved \(store.reviewModels.values.contains { $0.hasUnsavedEdits }), find \(store.terminalSearch.map { "open, total \($0.total.map(String.init) ?? "nil"), selected \($0.selected.map(String.init) ?? "nil")" } ?? "closed")" + ((window.firstResponder as? ReviewTextView).map { ", text \($0.string.prefix(16).debugDescription), can undo \($0.undoManager?.canUndo == true), can redo \($0.undoManager?.canRedo == true)" } ?? "")
            }
            print("start: \(state())")
            print("key window is snapshot: \(NSApp.keyWindow === window), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { note in
                print("  menu action: \((note.userInfo?["MenuItem"] as? NSMenuItem)?.title ?? "?")")
            }
            let keyCodes: [String: UInt16] = ["r": 15, "x": 7, "z": 6, "a": 0, "s": 1, "f": 3, "c": 8, "v": 9, "q": 12, "w": 13, "t": 17, "1": 18, "2": 19, "3": 20, "9": 25, "g": 5, "esc": 53, "]": 30, "[": 33, "enter": 36, "j": 38, "k": 40, ",": 43, "n": 45, "tab": 48, "=": 24, "-": 27]
            let flagNames: [String: NSEvent.ModifierFlags] = ["cmd": .command, "shift": .shift, "alt": .option, "ctrl": .control]
            let gap = UserDefaults.standard.string(forKey: "snapshotKeysGap").flatMap(Int.init) ?? 400
            for spec in keys.split(separator: " ").map(String.init) {
                if spec.hasPrefix("browse"), let index = Int(spec.dropFirst(6)), store.sidebarOrderedTabs.indices.contains(index) {
                    store.selectedTabID = store.sidebarOrderedTabs[index].id
                    print("\(spec) (sets the selection like ↑/↓ in the sidebar):\n  \(state())")
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
                if spec.hasPrefix("shot:") {
                    try? await Task.sleep(for: .milliseconds(500))
                    if let image = image(of: window) { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + ".\(spec.dropFirst(5)).png")) }
                    print("\(spec) (saves <out>.\(spec.dropFirst(5)).png):\n  \(state())")
                    continue
                }
                if let model = store.reviewModel, ["refresh", "keep", "save", "back", "forward", "files", "changes"].contains(spec) || spec.hasPrefix("file") || spec.hasPrefix("open:") || spec.hasPrefix("dbl:") {
                    let target = spec.split(separator: ":", maxSplits: 2).map(String.init)
                    let document = target.count == 3 ? ["u": ReviewDocument(path: target[2], compare: .uncommitted), "c": ReviewDocument(path: target[2], compare: .committed)][target[1]] ?? model.workingDocument(target[2]) : nil
                    if spec == "refresh" { await model.load() }
                    if spec == "keep" { model.selectedTabID.map(model.keep) }
                    if spec == "save", let path = model.selectedDocument?.path, let draft = model.drafts[path] { model.save(draft, to: path) }
                    if spec == "back" || spec == "forward" { model.go(by: spec == "back" ? -1 : 1) }
                    if spec == "files" || spec == "changes" { model.list = spec == "files" ? .files : .changes }
                    if spec.hasPrefix("file"), let index = Int(spec.dropFirst(4)), let file = model.changes.map({ $0.uncommitted.map { ReviewDocument(path: $0.path, compare: .uncommitted) } + $0.committed.map { ReviewDocument(path: $0.path, compare: .committed) } })?.dropFirst(index).first { model.open(file) }
                    if let document {
                        model.list = target[1] == "f" ? .files : .changes
                        model.open(document)
                        if target[0] == "dbl" { model.selectedTabID.map(model.keep) }
                    }
                    try? await Task.sleep(for: .seconds(1))
                    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                    let right = descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }.last
                    if let right, spec != "files", spec != "changes" { window.makeFirstResponder(right) }
                    print("\(spec) (\(target.count == 3 ? "\(target[0] == "dbl" ? "double-clicks" : "clicks") that row" : spec == "keep" ? "double-clicks the current tab" : spec == "refresh" ? "reloads Review" : Int(spec.dropFirst(4)) != nil ? "clicks that Changes row" : spec), then focuses the diff's right side): right side editable \(right?.isEditable == true), left shown \(right?.unifiedOriginal == nil), the path's editor \(right.map { right in model.editors.values.contains { $0 === right } } ?? false), language \(right?.onDefinition != nil)\n  \(state())")
                    continue
                }
                let parts = spec.split(separator: "+").map(String.init)
                guard let key = parts.last, let keyCode = keyCodes[key] else { continue }
                let flags = NSEvent.ModifierFlags(parts.dropLast().compactMap { flagNames[$0] })
                let characters = ["enter": "\r", "tab": "\t", "esc": "\u{1B}"][key] ?? key
                print("\(spec):")
                // Only a synthesized plain key sent to the window types; only a CGEvent-backed chord (51 is its private window number field) matches ⇧⌘Z.
                if flags.isEmpty, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) {
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
            let special: [String: (keyCode: UInt16, characters: String)] = ["down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "enter": (36, "\r"), "alt-enter": (36, "\r")]
            let letters: [Character: UInt16] = ["h": 4, "u": 32, "b": 11, "x": 7, "i": 34, "-": 27]
            for spec in keys.split(separator: " ").map(String.init) {
                let strokes = special[spec].map { [$0] } ?? spec.compactMap { character in letters[character].map { (keyCode: $0, characters: String(character)) } }
                for stroke in strokes {
                    let flags: NSEvent.ModifierFlags = spec == "alt-enter" ? .option : special[spec] != nil && spec != "enter" ? [.function, .numericPad] : []
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: stroke.characters, charactersIgnoringModifiers: stroke.characters, isARepeat: false, keyCode: stroke.keyCode) else { continue }
                    window.sendEvent(event)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                print("\(spec): launcher \(String(describing: store.launcherMode))")
            }
            print("openClaude calls: \(store.probeOpenedClaude.count) \(store.probeOpenedClaude.map { "\(URL(filePath: $0.cwd).lastPathComponent) \($0.start)" })")
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

    private static func describe(_ model: ReviewModel) -> String {
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
        return output.split(separator: "\n").filter { $0.contains("/dev/ptmx") }.count
    }

    private static func fail(_ message: String) -> Never {
        ProcessAncestry.hangUpDescendants()
        FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
        exit(1)
    }

    // cacheDisplay skips Liquid Glass and Metal; CGWindowListCreateImage is SDK-obsoleted but still exported and captures own windows without Screen Recording.
    private static func image(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        return create(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}

private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
#endif
