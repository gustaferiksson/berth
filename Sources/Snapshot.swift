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

    static let launcherKeys = UserDefaults.standard.string(forKey: "snapshotLauncherKeys")

    private static let hubFolders: [SessionSummary] = {
        let code = NSTemporaryDirectory() + "berth-launcher-keys"
        for name in ["x-hub-ui", "x-hub"] { try? FileManager.default.createDirectory(atPath: "\(code)/\(name)", withIntermediateDirectories: true) }
        return [
            SessionSummary(id: "fixture-hub-ui", cwd: "\(code)/x-hub-ui", title: "Fixture UI", lastActivity: .now - 420),
            SessionSummary(id: "fixture-hub", cwd: "\(code)/x-hub", title: "Fixture API", lastActivity: .now - 72_000),
        ]
    }()

    static let fixtureSessions = UserDefaults.standard.bool(forKey: "snapshotLongNames") ? longNames.map(\.session) : launcherKeys != nil ? hubFolders : nil
    static let fixturePullRequestStates = UserDefaults.standard.bool(forKey: "snapshotLongNames") ? Dictionary(uniqueKeysWithValues: longNames.compactMap { item in item.session.pullRequest.flatMap { link in item.state.map { (link.url, $0) } } }) : [:]
    #else
    static let fixtureSessions: [SessionSummary]? = nil
    static let launcherKeys: String? = nil
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
        await store.waitForScan()
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
            for _ in faked { store.openShell(cwd: FileManager.default.homeDirectoryForCurrentUser.path) }
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
        if let reviewFolder {
            store.openShell(cwd: reviewFolder)
            store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: reviewFolder, sessionID: "snapshot-review", terminal: $0.terminal) : $0 }
            if AppAction.reviewChanges.isAvailable(in: store) { AppAction.reviewChanges.perform(on: store) }
            store.reviewModels["snapshot-review"]?.selectedPath = UserDefaults.standard.string(forKey: "snapshotReviewFile")
            store.reviewModels["snapshot-review"]?.comments = [ReviewComment(id: "fixture", path: "README.md", line: 3, endLine: 5, text: "Fixture comment: tighten this paragraph.", snippet: "")]
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
        if reviewFolder != nil, let model = store.reviewModels["snapshot-review"] {
            let deadline = Date.now + 30
            while Date.now < deadline, model.error == nil, model.snapshot?.files.isEmpty != true, model.selectedPath.flatMap({ model.contents[$0] }) == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1))
            print("review \(model.snapshot.map { "\($0.branch) → \($0.base), fetch error \($0.fetchError ?? "-")" } ?? "error \(model.error ?? "timed out")")")
            for file in model.snapshot?.files ?? [] { print("  \(file.status.rawValue) \(file.path) +\(file.additions.map(String.init) ?? "?") -\(file.deletions.map(String.init) ?? "?")") }
            print("review selected \(model.selectedPath ?? "-"), contents loaded \(model.selectedPath.flatMap { model.contents[$0] } != nil), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let sides = descendants(window.contentView ?? NSView()).compactMap { $0 as? ReviewTextView }
            let clips = { sides.map { "\($0.enclosingScrollView?.contentView.bounds.minY ?? -1)" }.joined(separator: "/") }
            let save = { (suffix: String) in
                guard let image = image(of: window) else { return }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
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
                let arithmetic = unchanged.filter { pair in rows[1][pair.1].map { $0 != sides[1].top(ofRow: diff.modified.rows[pair.1]) } ?? false }.count
                print("\(label) hunks \(diff.hunks.count), checked \(checks.count), misaligned \(checks.filter { $0.1 != $0.2 }.count), unchanged pairs misaligned \(shifted), off top(ofRow:) \(arithmetic): " + checks.prefix(6).map { "\($0.0.originalLines)/\($0.0.modifiedLines) next row y \($0.1)/\($0.2)" }.joined(separator: ", "))
            }
            report("review")
            if let edit = UserDefaults.standard.string(forKey: "snapshotReviewEdit"), let right = sides.last {
                window.makeFirstResponder(right)
                right.setSelectedRange(NSRange(location: 0, length: 0))
                right.insertText(edit, replacementRange: right.selectedRange())
                try? await Task.sleep(for: .seconds(2))
                print("review after edit: draft \(model.drafts[model.selectedPath ?? ""] != nil), undo \(right.undoManager?.canUndo ?? false), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
                report("edited")
            }
            let scrollY = UserDefaults.standard.double(forKey: "snapshotReviewScroll")
            if scrollY > 0, let right = sides.last {
                right.scroll(NSPoint(x: 0, y: scrollY))
                try? await Task.sleep(for: .milliseconds(500))
                report("scrolled")
            }
            if let spec = UserDefaults.standard.string(forKey: "snapshotReviewWheel"), sides.count == 2, let separator = spec.firstIndex(of: ":"), let delta = Int32(spec[spec.index(after: separator)...]), let scrollView = (spec[..<separator] == "left" ? sides[0] : sides[1]).enclosingScrollView {
                let point = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
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
            func descendantViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantViews) }
            if let spec = UserDefaults.standard.string(forKey: "snapshotReviewMinimap"), let minimap = descendantViews(window.contentView ?? NSView()).compactMap({ $0 as? ReviewMinimap }).first {
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
                let drag = {
                    let ys = lines.map { line in
                        var y: CGFloat = 0
                        side.enumerateRows(in: side.bounds) { index, row, _, startsLine in if startsLine, index == line - 1 { y = row.midY } }
                        return side.gutter.map { $0.convert(side.convert(NSPoint(x: 0, y: y), to: nil), from: nil).y } ?? 0
                    }
                    if let gutter = side.gutter { mouse(gutter, ys + [ys.last ?? 0]) }
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
                print("typed: field \(draft()?.field.string.debugDescription ?? "-"), draft height \(draft()?.frame.height ?? -1), reserved \(sides[1].reserved)")
                report("typed")
                type("\r", 36, [])
                try? await Task.sleep(for: .milliseconds(500))
                print("comments: \(model.comments.map { "\($0.path):\($0.line)-\($0.endLine) \($0.side) \($0.text.debugDescription) snippet \($0.snippet.debugDescription)" }), draft \(draft() == nil ? "closed" : "open")")
                report("card")
                save(".card.png")
                if UserDefaults.standard.bool(forKey: "snapshotReviewDelete") {
                    let button = sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment }.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.toolTip == "Delete Comment" }
                    button?.performClick(nil)
                    try? await Task.sleep(for: .milliseconds(500))
                    let cards = { sides.flatMap(\.subviews).compactMap { $0 as? ReviewInlineComment }.count }
                    print("after card delete: comments \(model.comments.map(\.id)), cards \(cards())")
                    report("deleted")
                    model.comments.append(ReviewComment(id: "list", path: model.selectedPath ?? "", line: 1, endLine: 1, text: "From the list", snippet: ""))
                    try? await Task.sleep(for: .milliseconds(500))
                    let added = cards()
                    model.comments.removeAll { $0.id == "list" }
                    try? await Task.sleep(for: .milliseconds(500))
                    print("model append then list delete: cards \(added) → \(cards()), reserved \(sides[1].reserved)")
                }
            }
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
        if let keys = UserDefaults.standard.string(forKey: "snapshotKeys") {
            SettingsSnapshot.keepWindowsOffScreen()
            window.identifier = NSUserInterfaceItemIdentifier("main-snapshot")
            let keyWindow: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
            let isKey: @convention(block) (NSWindow) -> Bool = { $0 === window }
            method_setImplementation(class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.keyWindow))!, imp_implementationWithBlock(keyWindow))
            method_setImplementation(class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.isKeyWindow))!, imp_implementationWithBlock(isKey))
            if store.reviewSessionID == nil { window.makeFirstResponder(store.focusedTerminal?.attachedPlatformView ?? window.contentView) }
            let state = {
                let focused = store.tabs.firstIndex { $0.terminal.attachedPlatformView === window.firstResponder }.map { "#\($0)" } ?? window.firstResponder.map { "\(type(of: $0))" } ?? "nil"
                return "tabs \(store.tabs.enumerated().map { "\($1.kind)#\($0)" }), selected \(store.tabs.firstIndex { $0.id == store.selectedTabID }.map { "#\($0)" } ?? "none"), focused \(focused), terminals \(store.terminals.count) in \(store.terminals.map { URL(filePath: $0.folder).lastPathComponent }), review \(store.reviewSessionID != nil), unsaved \(store.reviewModels.values.contains { $0.hasUnsavedEdits })"
            }
            print("start: \(state())")
            print("key window is snapshot: \(NSApp.keyWindow === window), first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { note in
                print("  menu action: \((note.userInfo?["MenuItem"] as? NSMenuItem)?.title ?? "?")")
            }
            let keyCodes: [String: UInt16] = ["r": 15, "x": 7, "z": 6, "a": 0, "s": 1, "f": 3, "c": 8, "v": 9, "q": 12, "w": 13, "t": 17, "1": 18, "2": 19, "3": 20, "9": 25, "]": 30, "[": 33, "enter": 36, "j": 38, "k": 40, ",": 43, "n": 45, "tab": 48, "=": 24, "-": 27]
            let flagNames: [String: NSEvent.ModifierFlags] = ["cmd": .command, "shift": .shift, "alt": .option, "ctrl": .control]
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
                let parts = spec.split(separator: "+").map(String.init)
                guard let key = parts.last, let keyCode = keyCodes[key] else { continue }
                let flags = NSEvent.ModifierFlags(parts.dropLast().compactMap { flagNames[$0] })
                let characters = ["enter": "\r", "tab": "\t"][key] ?? key
                let shifted = flags.contains(.shift) ? ["[": "{", "]": "}", ",": "<"][characters] ?? characters.uppercased() : characters
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: shifted, charactersIgnoringModifiers: shifted, isARepeat: false, keyCode: keyCode) else { continue }
                print("\(spec):")
                NSApp.sendEvent(event)
                try? await Task.sleep(for: .milliseconds(400))
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
            let special: [String: (keyCode: UInt16, characters: String)] = ["down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "enter": (36, "\r")]
            let letters: [Character: UInt16] = ["h": 4, "u": 32, "b": 11, "x": 7, "i": 34, "-": 27]
            for spec in keys.split(separator: " ").map(String.init) {
                let strokes = special[spec].map { [$0] } ?? spec.compactMap { character in letters[character].map { (keyCode: $0, characters: String(character)) } }
                for stroke in strokes {
                    let flags: NSEvent.ModifierFlags = special[spec] != nil && spec != "enter" ? [.function, .numericPad] : []
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: stroke.characters, charactersIgnoringModifiers: stroke.characters, isARepeat: false, keyCode: stroke.keyCode) else { continue }
                    window.sendEvent(event)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                print("\(spec): launcher \(String(describing: store.launcherMode))")
            }
            print("openClaude calls: \(store.probeOpenedClaude.count) \(store.probeOpenedClaude.map { URL(filePath: $0).lastPathComponent })")
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
        print("review \(store.reviewSessionID ?? "off")")
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
