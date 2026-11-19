#if DEBUG
import AppKit
import BerthCore

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
        let folder = FileManager.default.currentDirectoryPath + "/.build/tasks-review"
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", tasksReviewScript, "sh", folder]
        try? process.run()
        process.waitUntilExit()
        return folder
    }()

    static let tasksReviewSession = UserDefaults.standard.string(forKey: "snapshotTasksReviewSession") ?? "task-usage-api"

    static func prepareTasksReview(store: Store) {
        let session = tasksReviewSession
        let folder = store.sessionsByID[session]?.cwd ?? tasksReviewFolder + "/billing"
        store.openShell(cwd: folder)
        store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: folder, sessionID: session, terminal: $0.terminal) : $0 }
        let edited = RepositoryRoot.resolve(tasksReviewFolder + (session == "task-usage-api" ? "/infra" : "/billing"))
        store.editedRepositories[session] = [edited: edited]
        if AppAction.showChanges.isAvailable(in: store) { AppAction.showChanges.perform(on: store) }
        store.prepareReviewModel()
    }

    static func captureTasksReview(store: Store, window: NSWindow, output: URL) async {
        let own = tasksReviewSession
        let save = { (suffix: String) in
            guard let image = image(of: window) else { return }

            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
        }
        let deadline = Date.now + 30
        while Date.now < deadline, store.sessionReviewModels.count < 3 || store.sessionReviewModels.contains(where: { $0.changes == nil && $0.error == nil }) { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(2))
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
            print("task card: \(store.title(of: task)) | issue \(task.issue.map { "\($0.repository)#\($0.number)" } ?? "none") | members \(members.map(\.id)) | PRs \(store.pullRequestCount(of: members)) | collapsed \(store.collapsedReviewRepositories.contains(task.id))")
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
        let open = { (name: String, path: String, compare: ReviewCompare?) async in
            guard let model = models.first(where: { $0.0 == name })?.1 else { return }

            model.open(ReviewDocument(path: path, compare: compare))
            try? await Task.sleep(for: .seconds(2))
            let active = store.reviewModel
            print("opened \(name):\(path) -> active root \(store.activeReviewRoots[own] ?? "own"), active is \(active === model ? name : "another model"), \(active.map(describe) ?? "no model"), contents loaded \(active?.selectedDocument.flatMap { active?.contents[$0] } != nil)")
            save(".\(name).png")
        }
        await open("web", "src/ExportButton.tsx", .committed)
        await open("infra", "cache.yml", .uncommitted)
        await open("billing", "src/export.swift", .committed)
        await open("web", "src/App.tsx", .uncommitted)
        let webRoot = RepositoryRoot.resolve(tasksReviewFolder + "/web")
        store.collapsedReviewRepositories.insert(webRoot)
        try? await Task.sleep(for: .seconds(1))
        describeRepositories("web collapsed")
        save(".web-collapsed.png")
        store.collapsedReviewRepositories.remove(webRoot)
        if let task = store.task(containing: own) {
            store.collapsedReviewRepositories.insert(task.id)
            try? await Task.sleep(for: .seconds(1))
            save(".card-folded.png")
            store.collapsedReviewRepositories.remove(task.id)
        }
        models.first { $0.0 == "infra" }?.1?.comments = [ReviewComment(id: "infra-comment", path: "cache.yml", line: 1, endLine: 1, text: "Pin the cache version.", snippet: "cache: v1")]
        models.first { $0.0 == "billing" }?.1?.comments = [ReviewComment(id: "billing-comment", path: "src/csv.swift", line: 1, endLine: 1, text: "Quote the header row.", snippet: "func csv() {}", compare: .committed)]
        try? await Task.sleep(for: .seconds(1))
        save(".comments.png")
        for (name, model) in models {
            guard let model, !model.comments.isEmpty, let changes = model.changes else { continue }

            let repository = name == "billing" ? nil : (name: name, path: RepositoryRoot.resolve(tasksReviewFolder + "/" + name))
            print("send prompt for \(name):\n" + ReviewComment.prompt(for: model.comments, branch: changes.branch, base: changes.base ?? "HEAD", repository: repository))
        }
        let infraModel = models.first { $0.0 == "infra" }?.1
        let before = infraModel?.changes?.uncommitted.count ?? -1
        try? "watched\n".write(toFile: tasksReviewFolder + "/infra/watched.txt", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(5))
        print("infra uncommitted files before touching its folder \(before), after the watcher reloaded \(infraModel?.changes?.uncommitted.count ?? -1)")
        try? FileManager.default.removeItem(atPath: tasksReviewFolder + "/infra/watched.txt")
        for member in store.task(containing: own)?.sessionIDs ?? [] { print("member row click activates \(member)") }
    }
}
#endif
