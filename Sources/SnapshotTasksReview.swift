#if DEBUG
import AppKit
import BerthCore
import GhosttyTerminal

extension Snapshot {
    private static let tasksReviewScript = """
    set -e
    rm -rf "$1"
    mkdir -p "$1"
    export GIT_CEILING_DIRECTORIES="$1"
    repository() {
      mkdir -p "$1/$2" && cd "$1/$2" && git init -q -b main
    }
    repository "$1" billing
    printf '# Billing\\n' > README.md
    mkdir src docs
    printf 'func export() {}\\n' > src/export.swift
    git add . && git commit -q -m init
    git checkout -q -b usage-export
    printf 'func export() {}\\nfunc exportRows() {}\\n' > src/export.swift
    printf 'func csv() {}\\n' > src/csv.swift
    git add . && git commit -q -m "Add the usage export"
    printf '# Billing\\nUsage export\\n' > README.md
    printf 'columns\\n' > docs/columns.md
    repository "$1" web
    mkdir src
    printf 'export const App = 1\\n' > src/App.tsx
    git add . && git commit -q -m init
    git checkout -q -b feat/export-button
    printf 'export const Button = 1\\n' > src/ExportButton.tsx
    git add . && git commit -q -m "Add the export button"
    printf 'export const App = 2\\n' > src/App.tsx
    repository "$1" infra
    printf 'name: ci\\n' > ci.yml
    git add . && git commit -q -m init
    git checkout -q -b ci-cache
    printf 'name: ci\\ncache: true\\n' > ci.yml
    printf 'cache: v1\\n' > cache.yml
    """

    static let tasksReviewFolder: String = {
        try? FileManager.default.createDirectory(atPath: tasksReviewParent, withIntermediateDirectories: true)
        let folder = FileManager.default.currentDirectoryPath + "/.build/tasks-review"
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", tasksReviewScript, "sh", folder]
        try? process.run()
        process.waitUntilExit()
        return folder
    }()

    static let tasksReviewParent = NSTemporaryDirectory() + "berth-tasks-review-parent"

    static let tasksReviewSession = UserDefaults.standard.string(forKey: "snapshotTasksReviewSession") ?? "task-usage-api"

    static func prepareTasksReview(store: Store) {
        let session = tasksReviewSession
        let folder = store.sessionsByID[session]?.cwd ?? tasksReviewFolder + "/billing"
        store.openShell(cwd: folder, command: UserDefaults.standard.string(forKey: "snapshotRemoteLog").map { "/usr/bin/tee -a '\($0)'" })
        store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: folder, sessionID: session, terminal: $0.terminal) : $0 }
        let names = ["task-usage-api": ["infra"], "task-parent": ["billing", "web"]][session] ?? ["billing"]
        let edited = names.map { RepositoryRoot.resolve(tasksReviewFolder + "/" + $0) }
        if !UserDefaults.standard.bool(forKey: "snapshotTasksReviewTranscript") { store.editedRepositories[session] = Dictionary(uniqueKeysWithValues: edited.map { ($0, $0) }) }
        if UserDefaults.standard.string(forKey: "snapshotRemoteLog") != nil, let live = try? JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":1,"sessionId":"\#(session)","cwd":"\#(folder)","status":"idle","startedAt":0}"#.utf8)) {
            store.fakeLiveSessions = [live]
            store.refreshLive()
        }
        if AppAction.showChanges.isAvailable(in: store) { AppAction.showChanges.perform(on: store) }
        store.prepareReviewModel()
        store.refreshEditedRepositories()
    }

    static func captureTasksReview(store: Store, window: NSWindow, output: URL) async {
        let own = tasksReviewSession
        let save = { (suffix: String) in
            guard let image = image(of: window) else { return }

            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
        }
        let deadline = Date.now + 30
        while Date.now < deadline, store.sessionReviewModels.count < 3 || store.sessionReviewModels.contains(where: { $0.changes == nil && $0.error == nil }) { try? await Task.sleep(for: .milliseconds(100)) }
        if let name = UserDefaults.standard.string(forKey: "snapshotReviewRepoTab"), let task = store.task(containing: own) {
            store.reviewRepoTabs[task.id] = name == "all" ? name : RepositoryRoot.resolve(tasksReviewFolder + "/" + name)
        }
        if UserDefaults.standard.bool(forKey: "snapshotReviewCommitsExpanded") { store.sessionReviewModels.forEach { $0.showsCommits = true } }
        try? await Task.sleep(for: .seconds(2))
        print("transcript of \(own): \(store.index.url(ofSession: own)?.lastPathComponent ?? "not indexed") (claude directory \(Store.claudeDirectory.path)), edited repositories \(store.editedRepositories[own]?.keys.map { URL(filePath: $0).lastPathComponent } ?? [])")
        if own != "task-usage-api" {
            let title = store.task(containing: own).map(store.title(of:)) ?? "none"
            let repositories = store.reviewRepositories[own] ?? []
            print("session \(own): task \(title), repositories \(repositories.map { "\($0.name)\($0.isEdited ? " (edited)" : "")" })")
            save(".stack.png")
            return
        }
        let key = { (name: String) in Store.reviewKey(own, root: RepositoryRoot.resolve(tasksReviewFolder + "/" + name)) }
        let models = [("billing", store.reviewModels[own]), ("web", store.reviewModels[key("web")]), ("infra", store.reviewModels[key("infra")])]
        if let task = store.task(containing: own) {
            let members = task.sessionIDs.compactMap { store.sessionsByID[$0] }
            print("task card: \(store.title(of: task)) | issue \(task.issue.map { "\($0.repository)#\($0.number)" } ?? "none") | members \(members.map(\.id)) | PRs \(store.pullRequestCount(of: members, in: task)) | collapsed \(store.collapsedReviewRepositories.contains(task.id))")
        } else {
            print("task card: none")
        }
        let describeRepositories = { (label: String) in
            print("repository sections \(label):")
            for (name, model) in models {
                guard let model, let changes = model.changes else { print("  \(name): no model or changes"); continue }

                let pullRequests = store.pullRequests(inRoot: name == "billing" ? nil : RepositoryRoot.resolve(tasksReviewFolder + "/" + name), of: own, branch: changes.branch)
                let collapsed = store.collapsedReviewRepositories.contains(RepositoryRoot.resolve(tasksReviewFolder + "/" + name))
                print("  \(name)\(collapsed ? " (collapsed)" : ""): \(changes.branch) → \(changes.base ?? "-") | PRs \(pullRequests.map { "#\($0.number) \($0.state.rawValue) checks \($0.checks?.rawValue ?? "-")" }) | uncommitted \(changes.uncommitted.map(\.path)) | committed \(changes.committed.map(\.path)) | base \(model.pullRequestBase.map { "\($0.base)" } ?? "-")")
            }
            print("  extras shown: \(store.reviewRepositories[own]?.map { "\($0.name)\($0.isEdited ? " (edited)" : "")" } ?? []), active root \(store.activeReviewRoots[own] ?? "own"), review roots \(store.sessionReviewModels.compactMap { $0.changes?.root.split(separator: "/").last.map(String.init) })")
        }
        describeRepositories("at start")
        save(".stack.png")
        if UserDefaults.standard.bool(forKey: "snapshotTasksReviewTransition"), let task = store.task(containing: own) {
            let infra = RepositoryRoot.resolve(tasksReviewFolder + "/infra")
            store.reviewRepoTabs[task.id] = infra
            try? await Task.sleep(for: .seconds(2))
            save(".infra-tab.png")
            store.editedRepositories[own] = [:]
            store.refreshEditedRepositories()
            try? await Task.sleep(for: .seconds(3))
            print("transition: repositories \(store.reviewRepositories[own]?.map(\.name) ?? []), picked \(store.reviewRepoTabs[task.id].map { URL(filePath: $0).lastPathComponent } ?? "-")")
            save(".infra-gone.png")
            if let tab = store.tabs.first(where: { $0.id == store.selectedTabID }), let index = store.tabs.firstIndex(where: { $0.id == tab.id }) {
                store.tabs[index].cwd = tasksReviewFolder + "/web"
                store.prepareReviewModel()
                try? await Task.sleep(for: .seconds(3))
                print("transition: relocated model folder \(store.reviewModels[own]?.folder ?? "-")")
                save(".relocated.png")
            }
        }
        if let names = UserDefaults.standard.string(forKey: "snapshotTasksReviewCollapse") {
            store.collapsedReviewRepositories.formUnion(names.split(separator: "|").map { RepositoryRoot.resolve(tasksReviewFolder + "/" + $0) })
            try? await Task.sleep(for: .seconds(2))
            save(".collapsed.png")
        }
        for step in (UserDefaults.standard.string(forKey: "snapshotTasksReviewDefaults") ?? "").split(separator: "|") {
            let pair = step.split(separator: "=")
            guard pair.count == 2 else { continue }

            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments[String(pair[0])] = String(pair[1])
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            try? await Task.sleep(for: .seconds(2))
            save(".\(pair[0])-\(pair[1]).png")
        }
        let points = Dictionary(uniqueKeysWithValues: (UserDefaults.standard.string(forKey: "snapshotTasksReviewPoints") ?? "").split(separator: "|").compactMap { entry -> (String, [Double])? in
            let parts = entry.split(separator: "=")
            return parts.count == 2 ? (String(parts[0]), parts[1].split(separator: ",").compactMap { Double($0) }) : nil
        })
        let click = { (name: String, count: Int) async in
            guard let point = points[name], point.count == 2 else { return }

            let location = NSPoint(x: point[0], y: (window.contentView?.frame.height ?? 0) - point[1])
            for number in 1...count {
                let event = { (type: NSEvent.EventType) in NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: number, pressure: type == .leftMouseDown ? 1 : 0) }
                event(.leftMouseUp).map { NSApp.postEvent($0, atStart: false) }
                event(.leftMouseDown).map(window.sendEvent)
            }
            try? await Task.sleep(for: .seconds(2))
        }
        let report = { (label: String) in
            let active = store.reviewModel
            print("\(label) -> active root \(store.activeReviewRoots[own].map { URL(filePath: $0).lastPathComponent } ?? "own"), \(active.map(describe) ?? "no model"), contents loaded \(active?.selectedDocument.flatMap { active?.contents[$0] } != nil), tabs per repository \(models.map { "\($0.0) \($0.1?.tabs.count ?? -1)" })")
        }
        await click("web", 2)
        report("double-click on web's Committed ExportButton.tsx")
        save(".web.png")
        await click("infra", 2)
        report("double-click on infra's Uncommitted cache.yml")
        save(".infra.png")
        models.first { $0.0 == "billing" }?.1?.open(ReviewDocument(path: "src/export.swift", compare: .committed))
        try? await Task.sleep(for: .seconds(2))
        report("own repo's file opened through its model")
        let webRoot = RepositoryRoot.resolve(tasksReviewFolder + "/web")
        store.collapsedReviewRepositories.insert(webRoot)
        try? await Task.sleep(for: .seconds(1))
        describeRepositories("web collapsed")
        save(".web-collapsed.png")
        store.collapsedReviewRepositories.remove(webRoot)
        if let task = store.task(containing: own) {
            await click("chevron", 1)
            print("after clicking the card's chevron: folded \(store.collapsedReviewRepositories.contains(task.id))")
            save(".card-folded.png")
            await click("chevron", 1)
            print("after clicking it again: folded \(store.collapsedReviewRepositories.contains(task.id))")
            await click("member", 1)
            print("after clicking the current member's row: selected session \(store.selectedSessionID ?? "-"), tabs \(store.tabs.count)")
        }
        models.first { $0.0 == "infra" }?.1?.comments = [ReviewComment(id: "infra-comment", path: "cache.yml", line: 1, endLine: 1, text: "Pin the cache version.", snippet: "cache: v1")]
        models.first { $0.0 == "billing" }?.1?.comments = [ReviewComment(id: "billing-comment", path: "src/csv.swift", line: 1, endLine: 1, text: "Quote the header row.", snippet: "func csv() {}", compare: .committed)]
        try? await Task.sleep(for: .seconds(1))
        save(".comments.png")
        let log = { (try? String(contentsOfFile: UserDefaults.standard.string(forKey: "snapshotRemoteLog") ?? "", encoding: .utf8)).debugDescription }
        await click("send", 1)
        _ = store.tab(forSession: own)?.terminal.sendKey(.enter)
        try? await Task.sleep(for: .seconds(1))
        print("after clicking Send: comments left \(models.map { "\($0.0) \($0.1?.comments.count ?? -1)" }), log \(log())")
        let infraModel = models.first { $0.0 == "infra" }?.1
        let before = infraModel?.changes?.uncommitted.count ?? -1
        try? "watched\n".write(toFile: tasksReviewFolder + "/infra/watched.txt", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(5))
        print("infra uncommitted files before touching its folder \(before), after the watcher reloaded \(infraModel?.changes?.uncommitted.count ?? -1)")
        try? FileManager.default.removeItem(atPath: tasksReviewFolder + "/infra/watched.txt")
    }
}
#endif
