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
    static let forcesPulse = UserDefaults.standard.bool(forKey: "snapshotPulse")
    #else
    static let forcesPulse = false
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
    private static let longNames: [(session: SessionSummary, state: PullRequestState?)] = {
        let code = NSTemporaryDirectory() + "berth-long-names"
        let billing = "\(code)/acme-platform-billing-reconciliation-pipeline-service"
        let onboarding = "\(code)/northwind-customer-onboarding-document-verification-worker"
        let legacy = "\(code)/acme-platform-billing-reconciliation-pipeline-service-legacy-adapter"
        for folder in [billing, onboarding, legacy, "\(code)/api"] { try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        return [
            (SessionSummary(id: "fixture-1", cwd: billing, title: "Reconcile ledger entries against settlement exports and flag every mismatch", lastActivity: .now - 120, branch: "feature/reconcile-settlement-exports-with-ledger-entries", pullRequest: PullRequestLink(number: 4821, url: URL(string: "https://github.com/acme/billing/pull/4821")!, repository: "acme/billing")), .open),
            (SessionSummary(id: "fixture-2", cwd: billing, title: "Fix rounding", lastActivity: .now - 900, branch: "fix/rounding", pullRequest: PullRequestLink(number: 4790, url: URL(string: "https://github.com/acme/billing/pull/4790")!, repository: "acme/billing")), .merged),
            (SessionSummary(id: "fixture-3", cwd: onboarding, title: "Retry document verification when the upstream provider times out", lastActivity: .now - 2400, branch: "chore/upgrade-document-verification-provider-sdk-to-latest-major"), nil),
            (SessionSummary(id: "fixture-4", cwd: "\(code)/api", title: "Draft the webhook signature check", lastActivity: .now - 3000, branch: "feature/webhook-signature-verification-with-rotating-secrets", pullRequest: PullRequestLink(number: 12, url: URL(string: "https://github.com/acme/billing/pull/12")!, repository: "acme/billing")), .draft),
            (SessionSummary(id: "fixture-5", cwd: onboarding, title: "Explain the onboarding state machine", lastActivity: .now - 4000), nil),
            (SessionSummary(id: "fixture-6", cwd: legacy, title: "Port the nightly settlement import", lastActivity: .now - 90_000, branch: "main", pullRequest: PullRequestLink(number: 99_999, url: URL(string: "https://github.com/acme/billing/pull/99999")!, repository: "acme/billing")), .closed),
        ]
    }()

    static let fixtureSessions = UserDefaults.standard.bool(forKey: "snapshotLongNames") ? longNames.map(\.session) : nil
    static let fixturePullRequestStates = UserDefaults.standard.bool(forKey: "snapshotLongNames") ? Dictionary(uniqueKeysWithValues: longNames.compactMap { item in item.session.pullRequest.flatMap { link in item.state.map { (link.url, $0) } } }) : [:]
    #else
    static let fixtureSessions: [SessionSummary]? = nil
    static let fixturePullRequestStates: [URL: PullRequestState] = [:]
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
    #else
    static let forcedHover: Set<String> = []
    #endif

    static func capture(to output: URL, store: Store) async {
        #if DEBUG
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let path = UserDefaults.standard.string(forKey: "snapshotCustomGroups"), let data = FileManager.default.contents(atPath: path) {
            store.customGroups = (try? JSONDecoder().decode([CustomGroup].self, from: data)) ?? []
        }
        await store.waitForScan()
        if UserDefaults.standard.bool(forKey: "snapshotFakeWaiting") {
            for (step, waiting) in [false, true, true, false, true].enumerated() {
                if step == 2, let session = store.groups.first(where: { !$0.sessions.isEmpty })?.sessions.first {
                    store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                    store.tabs = store.shells.map { Tab(id: $0.id, kind: .claude, cwd: session.cwd, sessionID: session.id, terminal: $0.terminal) }
                    store.shells = []
                    store.isPanelOpen = false
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
        if let path = UserDefaults.standard.string(forKey: "snapshotShellCd"), let shell = store.shells.first {
            Task {
                try? await Task.sleep(for: .seconds(2))
                _ = shell.terminal.paste(text: "cd \(path)")
                _ = shell.terminal.sendKey(.enter)
            }
        }
        if UserDefaults.standard.bool(forKey: "snapshotTogglePanel") {
            try? await Task.sleep(for: .seconds(2))
            store.toggleTerminalPanel()
            try? await Task.sleep(for: .seconds(1))
            store.toggleTerminalPanel()
        }
        let archiveRow = UserDefaults.standard.integer(forKey: "snapshotArchiveRow")
        if archiveRow > 0, let sessions = store.groups.first(where: { !$0.sessions.isEmpty })?.sessions, archiveRow <= sessions.count {
            store.archive(sessions[archiveRow - 1].id)
        }
        if UserDefaults.standard.bool(forKey: "snapshotArchiveTab") {
            for _ in 0..<2 { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
            store.tabs = store.shells.map { Tab(id: $0.id, kind: .claude, cwd: $0.cwd, sessionID: UUID().uuidString.lowercased(), terminal: $0.terminal) }
            store.selectedTabID = store.tabs.last?.id
            store.shells = []
            store.isPanelOpen = false
        }
        if UserDefaults.standard.bool(forKey: "snapshotHarbor") {
            let faked = store.liveBySession.values.filter { $0.pid == 1 }
            for _ in faked { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
            store.tabs = zip(store.shells, faked).map { Tab(id: $0.id, kind: .claude, cwd: $1.cwd, sessionID: $1.sessionId, terminal: $0.terminal) }
            store.selectedTabID = store.tabs.first?.id
            store.shells = []
            store.isPanelOpen = false
            store.isHarborShown = true
        }
        if let sessionID = UserDefaults.standard.string(forKey: "snapshotResume") {
            store.activate(.session(sessionID))
        }
        if let cwd = UserDefaults.standard.string(forKey: "snapshotClaude") {
            store.openClaude(cwd: cwd)
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
        let showsStats = UserDefaults.standard.bool(forKey: "snapshotStats")
        let root = editedGroup.map { AnyView(GroupEditor(group: $0).environment(\.ghosttyTheme, store.theme).preferredColorScheme(store.theme.isDark ? .dark : .light)) } ?? AnyView(showsStats ? AnyView(StatsView()) : AnyView(ContentView()))
        let hosting = NSHostingController(rootView: root.environment(store))
        hosting.sceneBridgingOptions = .all
        let window = UnconstrainedWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(editedGroup != nil ? hosting.view.fittingSize : showsStats ? NSSize(width: 960, height: 800) : NSSize(width: 1200, height: 760))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
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
        if UserDefaults.standard.bool(forKey: "snapshotToggleFrames") {
            for phase in ["hide", "show"] {
                let start = ContinuousClock.now
                store.toggleTerminalPanel()
                for frame in 0..<12 {
                    try? await Task.sleep(until: start + .milliseconds(frame * 40))
                    guard let image = image(of: window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                    try? png.write(to: output.deletingPathExtension().appendingPathExtension("\(phase)-\(frame * 40)ms.png"))
                }
            }
        }
        if UserDefaults.standard.bool(forKey: "snapshotCloseTabs") {
            let processes = ProcessAncestry.descendants()
            print("before close: \(processes.map(\.pid).sorted())")
            for tab in store.tabs + store.shells { store.close(tab.id) }
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
        if UserDefaults.standard.bool(forKey: "snapshotActivateFocus") {
            for step in ["open tab", "new tab"] {
                store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                store.tabs += store.shells.map { Tab(id: $0.id, kind: .claude, cwd: $0.cwd, sessionID: nil, terminal: $0.terminal) }
                store.shells = []
                store.isPanelOpen = false
                if step == "open tab" { try? await Task.sleep(for: .seconds(2)) }
                guard let target = store.tabs.last else { continue }
                window.makeFirstResponder(hosting.view)
                print("\(step) before activate: first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
                store.activate(.tab(target.id))
                try? await Task.sleep(for: .seconds(2))
                print("\(step) after activate: first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil"), is the activated surface \(window.firstResponder === target.terminal.attachedPlatformView)")
            }
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
            for item in menu.items + menu.items.compactMap(\.submenu).flatMap(\.items) where !item.isSeparatorItem {
                print("  \(item.state == .on ? "✓" : " ") \(item.title) \(item.keyEquivalentModifierMask.contains(.control) ? "⌃" : "")\(item.keyEquivalent)")
            }
        }
        print("shell starts: \((try? String(contentsOfFile: NSTemporaryDirectory() + "berth-shell-starts", encoding: .utf8))?.split(separator: "\n").count ?? 0)")
        for tab in store.tabs + store.shells { print("tab \(tab.kind) cwd=\(tab.cwd) session=\(tab.sessionID ?? "-") pwd=\(tab.terminal.workingDirectory ?? "-") title=\(tab.terminal.title)") }
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { fail("window is on screen") }
        guard let image = image(of: window) else { fail("window capture failed: number \(window.windowNumber) visible \(window.isVisible) frame \(window.frame)") }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: output)) != nil
        else { fail("could not write \(output.path)") }
        ProcessAncestry.hangUpDescendants()
        exit(0)
        #endif
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
