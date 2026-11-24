import BerthCore
import GhosttyTerminal
import SwiftUI

struct ReviewDocument: Hashable {
    enum PullRequestTab {
        case diff, details
    }

    let path: String
    let compare: ReviewCompare?
    var root: String?
    var pullRequestLink: PullRequestLink?
    var pullRequestTab: PullRequestTab?

    var pullRequestNumber: Int? { pullRequestLink?.number }
}

struct ReviewTab: Identifiable {
    let id: UUID
    var history: [(document: ReviewDocument, range: LanguageServerRange?)]
    var index: Int
    var isPreview: Bool

    var document: ReviewDocument { history[index].document }
}

nonisolated struct ReviewBlameSnapshot: Sendable {
    let id = UUID()
    let root: String
    let entries: [Int: ReviewBlame]
    let lineCount: Int
    var currentUser: String?
    var repository: String?
    var openCommit: (@MainActor (String) -> Void)?
}

private struct ReviewBlameKey: Hashable {
    let root: String
    let path: String
    let head: String
    let contentHash: Int
}

enum ReviewDiffLayout: String {
    case auto
    case sideBySide
    case inline

    static let key = "reviewDiffLayout"
}

@Observable
final class ReviewModel {
    let folder: String
    let isSessionFiles: Bool
    private(set) var changes: ReviewChanges?
    private(set) var status: ReviewBranchStatus?
    private(set) var tree: [ReviewFileTree] = []
    private(set) var pullRequestDetails: [Int: PullRequestDetail] = [:]
    private(set) var pullRequestStacks: [ReviewPullRequestStackKey: ReviewPullRequestStack] = [:]
    private(set) var pullRequestsForDetails: [PullRequestLink: PullRequest] = [:]
    private(set) var error: (any Error)?
    private(set) var isLoading = false
    private(set) var contents: [ReviewDocument: ReviewContents] = [:]
    private(set) var blameRevision = UUID()
    private(set) var language: ReviewLanguage?
    private(set) var tabs: [ReviewTab] = []
    private(set) var graphCommits: [GraphCommit] = []
    private(set) var graphRows: [GraphRow] = []
    private(set) var graphHasMore = false
    private(set) var graphHasLoaded = false
    private(set) var isLoadingGraph = false
    private(set) var graphError: String?
    private(set) var selectedCommit: String?
    private(set) var commitFiles: [String: [ReviewFile]] = [:]
    private(set) var pullRequestFiles: [ReviewPullRequestLocation: ReviewPullRequestFiles] = [:]
    private(set) var loadingPullRequests: [ReviewPullRequestLocation: Task<ReviewPullRequestFiles, any Error>] = [:]
    var expandedPullRequests: Set<PullRequestLink> = []
    var expansionOverrides: [String: Bool] = [:]
    var selectedTabID: UUID? {
        didSet { if selectedTabID != nil { isPreviewSelected = false } }
    }

    var isPreviewOpen = false
    var isPreviewSelected = false
    var showsCommentList = false
    var reveal: (document: ReviewDocument, range: LanguageServerRange)?
    var revealLine: (document: ReviewDocument, line: Int, side: ReviewComment.Side)?
    var changeStep: Int?
    var drafts: [String: String] = [:]
    var comments: [ReviewComment] = []
    var replyDrafts: [String: String] = [:]
    private(set) var isWritingPullRequest = false
    let preview = ReviewPreviewModel()
    var editingComment: String?
    var notice: String?
    var movedFolder: String?
    var focusesEditor = false
    @ObservationIgnored var pullRequestBase: (branch: String, base: String)?
    @ObservationIgnored var onOpen: () -> Void = {}
    var filesReveal: String?
    var expandedFolders: Set<String> = []
    var collapsedChangeFolders: Set<ReviewDocument> = []
    var collapsedSessionFolders: Set<String> = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var queuedLoad: Task<Void, Never>?
    @ObservationIgnored private var graphLoading: Task<Void, Never>?
    @ObservationIgnored private var commitSelection = 0
    @ObservationIgnored var rangeFiles: [ReviewDocument: ReviewFile] = [:]
    @ObservationIgnored private(set) var loadCount = 0
    var buffers: [String: ReviewEditBuffer] = [:]
    @ObservationIgnored private var blameCache: [ReviewBlameKey: Task<ReviewBlameSnapshot?, Never>] = [:]
    @ObservationIgnored private var pullRequestDetailsLoadedAt: [Int: (repository: String, date: Date)] = [:]
    @ObservationIgnored private var loadingPullRequestStacks: Set<ReviewPullRequestStackKey> = []
    @ObservationIgnored private var pullRequestStackDates: [ReviewPullRequestStackKey: Date] = [:]
    @ObservationIgnored private var pullRequestDiffSelection = UUID()
    @ObservationIgnored private(set) var editors: [String: ReviewTextView] = [:]
    @ObservationIgnored private var savedFromCommitted: Set<String> = []

    var hasUnsavedEdits: Bool { !drafts.isEmpty }
    var selectedTab: ReviewTab? { tabs.first { $0.id == selectedTabID } }
    var selectedDocument: ReviewDocument? { selectedTab?.document }
    var selectedDocumentHasBothSides: Bool {
        guard let document = selectedDocument else { return false }

        let status = listedFile(for: document)?.status
        return status?.hasOriginal == true && status != .deleted
    }

    static let baseBranchesKey = "reviewBaseBranches"
    private static let graphPageSize = 200

    init(folder: String) {
        self.folder = folder
        isSessionFiles = false
    }

    init() {
        folder = "/"
        isSessionFiles = true
    }

    func load() async {
        if let queuedLoad { return await queuedLoad.value }

        let load = Task { [previous = loading] in
            await previous?.value
            queuedLoad = nil
            await loadLists()
            if queuedLoad == nil { isLoading = false }
        }
        queuedLoad = load
        loading = load
        isLoading = true
        await load.value
    }

    private func loadLists() async {
        loadCount += 1
        defer {
            blameCache.removeAll()
            blameRevision = UUID()
        }
        if isSessionFiles {
            contents = contents.filter { $0.key == selectedDocument }
            if let selectedDocument { await loadContents(of: selectedDocument) }
            return
        }
        let refreshGraph = graphHasLoaded || isLoadingGraph || graphError != nil
        do {
            let picks = UserDefaults.standard.dictionary(forKey: Self.baseBranchesKey) as? [String: [String: String]] ?? [:]
            let pullRequestBase = pullRequestBase
            let changes = try await ReviewGit.changes(in: folder) { root, branch in (picks[root]?[branch], pullRequestBase?.branch == branch ? pullRequestBase?.base : nil) }
            if Store.shared.persistsTabs, picks[changes.root]?[changes.branch] != nil, changes.baseReason != .picked, changes.defaultBase != nil, !changes.isDefaultBranch {
                var kept = picks
                kept[changes.root]?[changes.branch] = nil
                UserDefaults.standard.set(kept, forKey: Self.baseBranchesKey)
            }
            let files = try await ReviewGit.files(in: changes.root)
            status = try? await ReviewGit.branchStatus(of: changes)
            self.changes = changes
            tree = ReviewFileTree.nodes(files)
            error = nil
            if language?.root != changes.root {
                language?.stop()
                language = ReviewLanguage(root: changes.root)
            }
            contents = contents.filter { $0.key == selectedDocument }

            let existing = { (document: ReviewDocument) -> ReviewDocument? in
                if document.pullRequestTab != nil || document.compare?.isHistorical == true || self.listedFile(for: document) != nil { return document }
                return FileManager.default.fileExists(atPath: URL(filePath: changes.root).appending(path: document.path).path) ? ReviewDocument(path: document.path, compare: nil) : nil
            }
            tabs = tabs.compactMap { tab in
                guard existing(tab.document) != nil else { return nil }

                let history = tab.history.compactMap { entry in existing(entry.document).map { (document: $0, range: entry.range) } }
                return ReviewTab(id: tab.id, history: history, index: tab.history[..<tab.index].compactMap { existing($0.document) }.count, isPreview: tab.isPreview)
            }
            for index in tabs.indices {
                let document = tabs[index].document
                guard document.compare == .committed, savedFromCommitted.contains(document.path), changes.uncommitted.contains(where: { $0.path == document.path }) else { continue }

                if tabs[index].id == selectedTabID, let editor = editors[document.path], editor.window?.firstResponder === editor { focusesEditor = true }
                tabs[index].history[tabs[index].index].document = ReviewDocument(path: document.path, compare: .uncommitted)
            }
            savedFromCommitted.subtract(changes.uncommitted.map(\.path))
            if selectedTab == nil { selectedTabID = tabs.last?.id }
        } catch {
            self.error = error
            return
        }
        if let selectedDocument { await loadContents(of: selectedDocument) }
        if refreshGraph {
            await graphLoading?.value
            await loadGraph()
        }
    }

    func loadGraph(more: Bool = false) async {
        if let graphLoading { return await graphLoading.value }
        guard let root = changes?.root, !more || graphHasMore else { return }

        let skip = more ? graphCommits.count : 0
        let limit = more ? Self.graphPageSize : max(Self.graphPageSize, graphCommits.count)
        isLoadingGraph = true
        let load = Task {
            defer {
                graphLoading = nil
                isLoadingGraph = false
            }
            do {
                let page = try await ReviewGit.graph(in: root, skip: skip, limit: limit)
                let loaded = Set(graphCommits.map(\.sha))
                if more, page.contains(where: { loaded.contains($0.sha) }) {
                    let refreshed = try await ReviewGit.graph(in: root, skip: 0, limit: skip + limit)
                    graphCommits = refreshed
                    graphHasMore = refreshed.count == skip + limit
                } else {
                    graphCommits = more ? graphCommits + page : page
                    graphHasMore = page.count == limit
                }
                graphRows = ReviewGraph.layout(graphCommits)
                if let selectedCommit, !graphCommits.contains(where: { $0.sha == selectedCommit }) { self.selectedCommit = nil }
                graphHasLoaded = true
                graphError = nil
            } catch {
                graphError = Self.describe(error)
            }
        }
        graphLoading = load
        await load.value
    }

    func openCommit(_ sha: String) async {
        guard let root = changes?.root else { return }

        selectedCommit = sha
        commitSelection += 1
        let selection = commitSelection
        do {
            let files = if let cached = commitFiles[sha] { cached } else { try await ReviewGit.commitFiles(sha, in: root) }
            commitFiles[sha] = files
            guard selection == commitSelection, selectedCommit == sha, let first = files.first else { return }

            open(ReviewDocument(path: first.path, compare: .commit(sha)))
        } catch {
            guard selection == commitSelection, selectedCommit == sha else { return }

            selectedCommit = nil
            notice = "Couldn’t read commit \(sha.prefix(7)). \(Self.describe(error))"
        }
    }

    func loadPullRequestFiles(_ entry: ReviewPullRequest) async throws -> ReviewPullRequestFiles {
        let location = entry.location
        let link = location.link
        if let pending = loadingPullRequests[location] { return try await pending.value }

        let task = Task {
            defer { loadingPullRequests[location] = nil }
            #if DEBUG
            if Snapshot.output != nil, Snapshot.reviewSelectedPullRequestNumber == link.number {
                pullRequestFiles[location] = Snapshot.reviewDiffFixture
                return Snapshot.reviewDiffFixture
            }
            #endif
            let result = try await ReviewGit.pullRequestFiles(number: link.number, repository: link.repository, base: entry.pullRequest.baseRefName, in: location.root)
            let loaded = ReviewPullRequestFiles(compare: .range(base: result.base, head: result.head), files: result.files)
            for file in loaded.files {
                rangeFiles[ReviewDocument(path: file.path, compare: loaded.compare, root: location.root, pullRequestLink: link)] = file
            }
            pullRequestFiles[location] = loaded
            return loaded
        }
        loadingPullRequests[location] = task
        return try await task.value
    }

    func expandPullRequest(_ entry: ReviewPullRequest) async {
        guard expandedPullRequests.insert(entry.id).inserted else { return }

        do {
            _ = try await loadPullRequestFiles(entry)
        } catch {
            expandedPullRequests.remove(entry.id)
            notice = "Couldn’t read PR #\(entry.id.number). \(Self.describe(error))"
        }
    }

    func openPullRequestDiff(_ entry: ReviewPullRequest) async {
        let link = entry.id
        let selection = UUID()
        pullRequestDiffSelection = selection
        if let tab = tabs.first(where: { $0.document.pullRequestTab == .diff && $0.document.pullRequestLink == link }) {
            open(tab.document)
            return
        }

        let previous = selectedDocument
        do {
            let loaded = try await loadPullRequestFiles(entry)
            guard selection == pullRequestDiffSelection, previous == selectedDocument, !Task.isCancelled else { return }

            open(ReviewDocument(path: loaded.files.first?.path ?? "", compare: loaded.compare, root: entry.location.root, pullRequestLink: link, pullRequestTab: .diff))
        } catch {
            guard selection == pullRequestDiffSelection, previous == selectedDocument, !Task.isCancelled else { return }

            notice = "Couldn’t read PR #\(link.number). \(Self.describe(error))"
        }
    }

    func selectPullRequestFile(_ file: ReviewFile, in document: ReviewDocument) {
        guard document == selectedDocument, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }

        let fileDocument = ReviewDocument(path: file.path, compare: document.compare, root: document.root, pullRequestLink: document.pullRequestLink, pullRequestTab: .diff)
        tabs[index].history[tabs[index].index] = (fileDocument, nil)
        reveal = nil
        revealLine = nil
    }

    func openPullRequestDetails(_ entry: ReviewPullRequest) {
        pullRequestsForDetails[entry.id] = entry.pullRequest
        open(ReviewDocument(path: "", compare: nil, pullRequestLink: entry.id, pullRequestTab: .details))
    }

    func pullRequestContents(_ document: ReviewDocument) async throws -> ReviewContents {
        #if DEBUG
        if Snapshot.output != nil, document.compare == Snapshot.reviewDiffFixture.compare { return Snapshot.reviewDiffContents }

        #endif
        guard let file = listedFile(for: document), let root = document.root, case let .range(base, head) = document.compare else {
            throw ReviewGitError.notARepository
        }

        return try await ReviewGit.contents(of: file, base: base, head: head, in: root)
    }

    func pickBase(_ ref: String) {
        guard let changes else { return }

        var picks = UserDefaults.standard.dictionary(forKey: Self.baseBranchesKey) as? [String: [String: String]] ?? [:]
        picks[changes.root, default: [:]][changes.branch] = ref
        UserDefaults.standard.set(picks, forKey: Self.baseBranchesKey)
        Task { await load() }
    }

    func open(_ document: ReviewDocument, loaded: ReviewContents? = nil) {
        if let loaded { contents[document] = loaded }
        revealLine = nil
        onOpen()
        if let shown = tabs.first(where: { $0.document == document }) {
            selectedTabID = shown.id
            return
        }
        guard let preview = tabs.firstIndex(where: \.isPreview) else {
            let tab = ReviewTab(id: UUID(), history: [(document, nil)], index: 0, isPreview: true)
            tabs.insert(tab, at: tabs.firstIndex { $0.id == selectedTabID }.map { $0 + 1 } ?? tabs.count)
            selectedTabID = tab.id
            return
        }

        tabs[preview].history = Array(tabs[preview].history.prefix(tabs[preview].index + 1)) + [(document, nil)]
        tabs[preview].index += 1
        selectedTabID = tabs[preview].id
    }

    func showPreview() {
        isPreviewOpen = true
        isPreviewSelected = true
    }

    func closePreview() {
        isPreviewOpen = false
        isPreviewSelected = false
    }

    func keep(_ id: ReviewTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        tabs[index].isPreview = false
    }

    func go(by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[index].history.indices.contains(tabs[index].index + offset) else { return }

        tabs[index].index += offset
        reveal = tabs[index].history[tabs[index].index].range.map { (tabs[index].document, $0) }
        focusesEditor = true
    }

    func close(_ id: ReviewTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        let showsPreview = isPreviewSelected
        tabs.remove(at: index)
        if selectedTabID == id { selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        isPreviewSelected = showsPreview
    }

    func changedDocument(at path: String) -> ReviewDocument? {
        if changes?.uncommitted.contains(where: { $0.path == path }) == true { return ReviewDocument(path: path, compare: .uncommitted) }

        return changes?.committed.contains { $0.path == path } == true ? ReviewDocument(path: path, compare: .committed) : nil
    }

    func workingDocument(_ path: String) -> ReviewDocument {
        ReviewDocument(path: path, compare: changes?.uncommitted.contains { $0.path == path } == true ? .uncommitted : nil)
    }

    func open(_ thread: ReviewThread) {
        let document = changes?.committed.contains { $0.path == thread.path } == true ? ReviewDocument(path: thread.path, compare: .committed) : workingDocument(thread.path)
        reveal = nil
        open(document)
        revealLine = thread.line.map { (document, $0, thread.side) }
    }

    func loadPullRequestDetail(repository: String, number: Int, throttled: Bool = false, stack: ReviewPullRequestStackKey? = nil) async {
        async let stackRefresh: Void = loadPullRequestStack(stack, throttled: throttled)
        let lastLoad = pullRequestDetailsLoadedAt[number]
        if let lastLoad, lastLoad.repository == repository {
            guard !throttled || lastLoad.date.timeIntervalSinceNow <= -60 else { return await stackRefresh }
        } else {
            pullRequestDetails[number] = nil
        }

        let started = Date.now
        pullRequestDetailsLoadedAt[number] = (repository, started)
        let detail = Snapshot.output != nil ? Snapshot.fixturePullRequestDetail : await Task.detached { PullRequestStatus.detail(repository: repository, number: number) }.value
        if let detail, pullRequestDetailsLoadedAt[number]?.date == started, pullRequestDetailsLoadedAt[number]?.repository == repository {
            pullRequestDetails[number] = detail
            pullRequestDetailsLoadedAt[number] = (repository, .now)
        }
        await stackRefresh
    }

    private func loadPullRequestStack(_ key: ReviewPullRequestStackKey?, throttled: Bool) async {
        guard let key, !loadingPullRequestStacks.contains(key), !throttled || (pullRequestStackDates[key]?.timeIntervalSinceNow ?? -.infinity) <= -60 else { return }

        loadingPullRequestStacks.insert(key)
        defer { loadingPullRequestStacks.remove(key) }
        let stack = Snapshot.output != nil ? Snapshot.reviewStackFixture : await Task.detached { PullRequestStatus.stack(key) }.value
        if let stack {
            pullRequestStacks[key] = stack
            pullRequestStackDates[key] = .now
        }
    }

    func sendReply(repository: String, number: Int, threadID: String, body: String) async -> Bool {
        guard !isWritingPullRequest else { return false }

        isWritingPullRequest = true
        defer { isWritingPullRequest = false }
        guard Snapshot.output == nil,
              await Task.detached(operation: { PullRequestStatus.reply(repository: repository, threadID: threadID, body: body) }).value
        else {
            notice = "Couldn’t add reply to the pending review"
            return false
        }

        await loadPullRequestDetail(repository: repository, number: number)
        replyDrafts[threadID] = nil
        return true
    }

    func sendToPullRequest(_ comment: ReviewComment, repository: String, number: Int) async {
        guard !isWritingPullRequest, comment.element == nil, comments.contains(comment) else { return }

        isWritingPullRequest = true
        defer { isWritingPullRequest = false }
        guard Snapshot.output == nil, pullRequestDetailsLoadedAt[number]?.repository == repository,
              let pullRequestID = pullRequestDetails[number]?.id,
              await Task.detached(operation: { PullRequestStatus.addThread(pullRequestID: pullRequestID, comment: comment) }).value
        else {
            notice = "Couldn’t add comment to the pending review"
            return
        }

        comments.removeAll { $0 == comment }
        await loadPullRequestDetail(repository: repository, number: number)
        notice = "Added to your pending review on GitHub"
    }

    func loadSelectedContents() async {
        guard let document = selectedDocument, contents[document] == nil else { return }

        await loadContents(of: document)
    }

    func loadBlame(for document: ReviewDocument) async -> ReviewBlameSnapshot? {
        let path = document.path
        guard document.compare == nil || document.compare == .uncommitted, let changes,
              case let .text(text)? = contents[document]?.modified,
              changes.uncommitted.first(where: { $0.path == path })?.status.hasOriginal != false
        else { return nil }

        let revision = blameRevision
        let contentHash = await Task.detached { text.hashValue }.value
        guard revision == blameRevision, !Task.isCancelled else { return nil }

        let key = ReviewBlameKey(root: changes.root, path: path, head: changes.head, contentHash: contentHash)
        let snapshot = await cachedBlame(for: key, text: text, changes: changes)
        guard var snapshot else { return nil }

        snapshot.openCommit = { [weak self] sha in Task { await self?.openCommit(sha) } }
        return snapshot
    }

    private func cachedBlame(for key: ReviewBlameKey, text: String, changes: ReviewChanges) async -> ReviewBlameSnapshot? {
        if let cached = blameCache[key] { return await cached.value }

        let task = Task.detached(priority: .utility) { () -> ReviewBlameSnapshot? in
            guard let blame = await ReviewGit.blame(key.path, at: changes.head, text: text, in: changes.root) else { return nil }

            async let user = ReviewGit.userName(in: changes.root)
            async let repository = RepositoryRoot.gitHubRepository(at: changes.root)
            return await ReviewBlameSnapshot(root: changes.root, entries: blame.entries, lineCount: blame.lineCount, currentUser: user, repository: repository)
        }
        blameCache[key] = task
        return await task.value
    }

    private func listedFile(for document: ReviewDocument) -> ReviewFile? {
        let files: [ReviewFile]
        switch document.compare {
        case .uncommitted: files = changes?.uncommitted ?? []

        case .committed: files = changes?.committed ?? []

        case let .commit(sha): files = commitFiles[sha] ?? []

        case .range:
            var file = document
            file.pullRequestTab = nil
            return rangeFiles[file]

        case nil: return nil
        }
        return files.first { $0.path == document.path }
    }

    func isReadOnly(_ document: ReviewDocument) -> Bool {
        if document.pullRequestTab != nil { return true }

        return switch document.compare {
        case .commit, .range: true
        case .committed: changes?.uncommitted.contains { $0.path == document.path } != false
        case .uncommitted: false
        case nil: isSessionFiles
        }
    }

    private func loadContents(of document: ReviewDocument) async {
        guard document.pullRequestTab != .details, !document.path.isEmpty else { return }

        if isSessionFiles {
            do {
                let text = try ReviewGit.plainText(at: URL(filePath: "/" + document.path))
                contents[document] = ReviewContents(original: text, modified: text)
            } catch {
                notice = "Couldn’t read /\(document.path): \(Self.describe(error))"
            }
            return
        }
        do {
            if document.pullRequestLink != nil {
                contents[document] = try await pullRequestContents(document)
                return
            }

            guard let changes else { return }

            let loaded: ReviewContents
            if let listed = listedFile(for: document), let compare = document.compare {
                loaded = try await ReviewGit.contents(of: listed, compare: compare, in: changes)
            } else {
                guard document.compare?.isHistorical != true else { return }

                let text = try ReviewGit.workingTreeText(document.path, in: changes.root)
                loaded = ReviewContents(original: text, modified: text)
            }
            contents[document] = loaded
            guard !isReadOnly(document) else { return }

            syncBuffer(of: document.path, with: loaded.modified)
            editors[document.path] = editors[document.path] ?? ReviewTextView(usingTextLayoutManager: true)
            setWorkingTreeText(loaded.modified, of: document.path)
        } catch {
            notice = "Couldn’t read \(document.path): \(Self.describe(error))"
        }
    }

    func goToDefinition(_ location: LanguageServerLocation, from origin: LanguageServerRange) {
        let target = location.url.resolvingSymlinksInPath().path
        guard let root = changes.map({ URL(filePath: $0.root).resolvingSymlinksInPath().path + "/" }), target.hasPrefix(root), let current = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[current].document.compare?.isHistorical != true else { return }

        let path = String(target.dropFirst(root.count))
        let isReadOnly = selectedDocument?.compare == .committed && changes?.uncommitted.contains { $0.path == path } != false
        let document = selectedDocument.flatMap { $0.path == path && !isReadOnly ? $0 : nil } ?? workingDocument(path)
        tabs[current].history[tabs[current].index].range = origin
        reveal = (document, location.range)
        if document == tabs[current].document {
            guard location.range.start != origin.start else { return }

            tabs[current].history = Array(tabs[current].history.prefix(tabs[current].index + 1)) + [(document, location.range)]
            tabs[current].index += 1
            return
        }

        open(document)
        if let landed = tabs.firstIndex(where: { $0.id == selectedTabID }) { tabs[landed].history[tabs[landed].index].range = location.range }
    }

    func workingText(_ path: String) -> String? {
        if let editor = editors[path] { return editor.string }
        guard let root = changes?.root, case let .text(text)? = try? ReviewGit.workingTreeText(path, in: root) else { return nil }

        return text
    }

    func save(_ text: String, to path: String) {
        guard selectedDocument?.compare?.isHistorical != true, let changes, changes.uncommitted.first(where: { $0.path == path })?.status != .deleted else {
            notice = "\(path) is read only here"
            return
        }
        guard isSafeToSave(text, to: path, in: changes.root) else { return }

        do {
            try ReviewGit.save(text, to: path, in: changes.root)
        } catch {
            notice = "Couldn’t save \(path): \(Self.describe(error))"
            return
        }
        buffers[path] = ReviewEditBuffer(base: text)
        drafts[path] = nil
        if selectedDocument == ReviewDocument(path: path, compare: .committed) { savedFromCommitted.insert(path) }
        setWorkingTreeText(.text(text), of: path)
        blameCache = blameCache.filter { $0.key.path != path }
        blameRevision = UUID()
    }

    private func setWorkingTreeText(_ text: ReviewText?, of path: String) {
        for document in contents.keys where document.path == path && !isReadOnly(document) {
            contents[document] = contents[document].map { ReviewContents(original: document.compare == nil ? text : $0.original, modified: text) }
        }
    }

    static func describe(_ error: any Error) -> String {
        guard case let ReviewGitError.git(_, message) = error else { return String(describing: error) }

        return message
    }
}

private extension Store {
    func shownReviewPullRequest(for model: ReviewModel, sessionID: String, root: String?, branchOnly: Bool = false) -> (repository: String, pullRequest: PullRequest?)? {
        guard let changes = model.changes else { return nil }

        let branch = changes.branch
        let looked: (repository: String, pullRequest: PullRequest?)? = if let root {
            pullRequestBranch(inRoot: root, branch: branch).flatMap { key in pullRequests[key].map { (key.repository, $0) } }
        } else {
            pullRequest(in: sessionsByID[sessionID]?.checkout ?? model.folder, branch: branch)
        }
        guard looked?.pullRequest == nil else { return looked }

        let linked = pullRequests(inRoot: root, of: sessionID, branch: branch).filter { !branchOnly || $0.headRefName == branch }
        let lookupRoot = root ?? repositoryRoot(ofSession: sessionID) ?? model.folder
        guard let first = linked.first(where: { [.open, .draft].contains($0.state) }) ?? linked.first,
              let repository = pullRequestBranch(inRoot: lookupRoot, branch: branch)?.repository else { return looked }

        return (repository, first)
    }

    @discardableResult
    func sendReviewPrompt(_ prompt: String, sessionID: String, noticeIn model: ReviewModel) -> Bool {
        guard liveBySession[sessionID] != nil, let terminal = tab(forSession: sessionID)?.terminal, terminal.paste(text: prompt) else {
            model.notice = "Claude isn’t running in this tab; comments kept"
            return false
        }

        terminal.requestFocus()
        return true
    }
}

struct ReviewPanel: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let model = store.primaryReviewModel, let sessionID = store.selectedSessionID {
            ReviewFileList(sessionID: sessionID, model: model)
                .id(ObjectIdentifier(model))
        } else {
            ContentUnavailableView("Select a Claude Session", systemImage: "plus.forwardslash.minus", description: Text("Its branch’s changes show here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ReviewFileList: View {
    let sessionID: String
    let model: ReviewModel
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage("collapsedReviewSections") private var collapsedSections = ""
    @AppStorage("reviewChangesAsTree") private var changesAsTree = false
    @FocusState private var focusedList: String?
    @State private var threadSectionScroll: String?
    @State private var keyboardNavigation: (row: ReviewDocument, selection: ReviewDocument?)?

    var body: some View {
        let shown = model.changes.flatMap { shownPullRequest(root: nil, branch: $0.branch) }
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task { await model.load() }
            .task { movePersistedPanelTab() }
            .task(id: [model.changes?.branch, pullRequest?.pullRequest?.baseRefName]) {
                let base = model.changes.flatMap { changes in pullRequest?.pullRequest?.baseRefName.map { (branch: changes.branch, base: $0) } }
                guard base?.branch != model.pullRequestBase?.branch || base?.base != model.pullRequestBase?.base else { return }

                model.pullRequestBase = base
                await model.load()
            }
            .onChange(of: store.activeReviewRoots[sessionID]) { _, root in
                guard let task = store.task(containing: sessionID), shownRepo != nil else { return }

                store.reviewRepoTabs[task.id] = root ?? ownRoot
            }
            .onChange(of: owners.contains { $0.model.hasUnsavedEdits || !$0.model.comments.isEmpty }) { store.prepareReviewModel() }
            .task(id: selection) { await (store.reviewModel ?? model).loadSelectedContents() }
            .task(id: extraStates) { for extra in extras { await prepare(extra.repository, extra.model) } }
            .task(id: [shown?.repository, shown?.pullRequest?.number.formatted(), branchStackKey?.head, branchStackKey?.base]) { await loadPullRequestDetail() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    for owner in owners {
                        guard let branch = owner.model.changes?.branch,
                              let shown = shownPullRequest(root: owner.repository?.root, branch: branch),
                              let number = shown.pullRequest?.number
                        else { continue }

                        await owner.model.loadPullRequestDetail(repository: shown.repository, number: number, throttled: true, stack: owner.model === model ? branchStackKey : nil)
                    }
                }
            }
            .alert("Review", isPresented: Binding(get: { noticeOwner != nil }, set: { if !$0 { noticeOwner?.notice = nil } }), presenting: noticeOwner?.notice) { _ in
            } message: { notice in
                Text(notice)
            }
    }

    @ViewBuilder private var content: some View {
        if model.changes != nil || !store.shownReviewPullRequests[sessionID, default: [:]].isEmpty {
            panel(model.changes)
        } else if let error = model.error, case ReviewGitError.notARepository = error, !extras.isEmpty || !sessionFiles.isEmpty {
            panel(nil)
        } else if let error = model.error, case ReviewGitError.notARepository = error {
            let failure = failure(error)
            ContentUnavailableView(failure.title, systemImage: failure.symbol, description: Text(failure.description))
        } else if let error = model.error {
            let failure = failure(error)
            ContentUnavailableView {
                Label(failure.title, systemImage: failure.symbol)
            } description: {
                Text(failure.description)
                if let detail = failure.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            } actions: {
                Button("Try Again", action: refresh)
                    .buttonStyle(.bordered)
                    .disabled(model.isLoading)
            }
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading changes…")
            }
        }
    }

    private func list(name: String, order: [ReviewDocument], @ViewBuilder _ sections: () -> some View) -> some View {
        let content = sections()
        let workingPath = model.selectedDocument.flatMap { $0.compare?.isHistorical == true ? nil : $0.path }
        let filesAreExpanded = filesAreExpanded
        let graphIsVisible = graphIsVisible
        return ScrollViewReader { proxy in
            List { content }
                .focusable(!order.isEmpty)
                .focused($focusedList, equals: name)
                .focusEffectDisabled()
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in step(1, in: order, proxy: proxy) }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in step(-1, in: order, proxy: proxy) }
                .onKeyPress(.return) {
                    let target = store.reviewModel ?? model
                    guard !order.isEmpty, let tab = target.selectedTabID else { return .ignored }

                    target.keep(tab)
                    return .handled
                }
                .listStyle(.plain)
                .environment(\.showsSidebarHeadersAsRows, true)
                .environment(\.defaultMinListRowHeight, 0)
                .environment(\.sidebarRowSize, .small)
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .task(id: graphIsVisible) {
                    guard graphIsVisible, !model.graphHasLoaded, model.graphError == nil else { return }

                    await model.loadGraph()
                }
                .onChange(of: graphIsVisible ? model.selectedCommit : nil, initial: true) { _, sha in
                    if let sha { Task { proxy.scrollTo(sha) } }
                }
                .onChange(of: threadSectionScroll, initial: true) { _, section in
                    guard let section else { return }

                    Task {
                        guard threadSectionScroll == section else { return }

                        proxy.scrollTo(section, anchor: .top)
                        threadSectionScroll = nil
                    }
                }
                .onChange(of: [workingPath, model.filesReveal, filesAreExpanded ? "files" : nil], initial: true) {
                    if model.filesReveal != nil {
                        if let task = store.task(containing: sessionID), shownRepo != nil, shownRepo != ownRoot {
                            store.reviewRepoTabs[task.id] = ownRoot
                        }
                        let files = expansion(of: "files", defaultExpanded: false)
                        if !files.wrappedValue { files.wrappedValue = true }
                    }
                    let followsWorkingPath = keyboardNavigation.map { $0.selection != selection } ?? true
                    guard filesAreExpanded, let path = model.filesReveal ?? (followsWorkingPath ? workingPath : nil) else { return }

                    model.filesReveal = nil
                    model.expandedFolders.formUnion(path.split(separator: "/").dropLast().reduce(into: [String]()) { $0.append(($0.last.map { $0 + "/" } ?? "") + $1) })
                    Task { proxy.scrollTo("file:" + path) }
                }
                .onChange(of: selection) {
                    if keyboardNavigation?.selection != selection { keyboardNavigation = nil }
                }
        }
    }

    private func step(_ offset: Int, in order: [ReviewDocument], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }

        let current = keyboardNavigation.flatMap { order.firstIndex(of: $0.row) } ?? selection.flatMap { order.firstIndex(of: $0) }
        let next = order[min(max((current ?? (offset > 0 ? -1 : order.count)) + offset, 0), order.count - 1)]
        open(next)
        keyboardNavigation = (next, selection)
        if case let .commit(sha)? = next.compare {
            proxy.scrollTo(sha)
        } else if next.compare == nil, next.root == nil {
            proxy.scrollTo("file:" + next.path)
        } else {
            proxy.scrollTo(next)
        }
        return .handled
    }

    private var filesAreExpanded: Bool {
        hasOwnRepository && expansion(of: "files", defaultExpanded: false).wrappedValue
    }

    private var branchCommits: [ReviewCommit] {
        model.changes?.isDefaultBranch == true ? [] : model.status?.commits ?? []
    }

    private var graphIsVisible: Bool {
        hasOwnRepository && expansion(of: "commits", defaultExpanded: false).wrappedValue
            && (model.changes?.isDefaultBranch == true || expansion(of: "history", defaultExpanded: false).wrappedValue)
    }

    private var graphFileOrder: [ReviewDocument] {
        guard graphIsVisible, let sha = model.selectedCommit, let files = model.commitFiles[sha] else { return [] }

        return files.map { ReviewDocument(path: $0.path, compare: .commit(sha)) }
    }

    private var filesOrder: [ReviewDocument] {
        guard filesAreExpanded else { return [] }

        return model.tree.flatMap { leaves(of: $0, compare: nil, root: nil, in: model) }
    }

    private func changeOrder(_ changes: ReviewChanges?) -> [ReviewDocument] {
        let ownAndExtraFiles = repositoryOrder(changes)
        let pullRequestFiles = expansion(of: "otherPullRequests", defaultExpanded: false).wrappedValue ? sessionPullRequests(in: changes).flatMap { group in
            group.entries.flatMap { entry -> [ReviewDocument] in
                guard group.model.expandedPullRequests.contains(entry.id), group.model.loadingPullRequests[entry.location] == nil, let loaded = group.model.pullRequestFiles[entry.location] else { return [] }

                return loaded.files.map { ReviewDocument(path: $0.path, compare: loaded.compare, root: entry.location.root, pullRequestLink: entry.id) }
            }
        } : []
        return pullRequestFiles + ownAndExtraFiles + sessionFileOrder
    }

    private func repositoryOrder(_ changes: ReviewChanges?) -> [ReviewDocument] {
        if !isStacked || shownRepo != nil {
            let extra = extras.first { $0.repository.root == shownRepo }
            let root = extra?.repository.root
            let target = extra?.model ?? model
            guard let changes = target.changes else { return [] }

            let sections: [(compare: ReviewCompare, files: [ReviewFile])] = [(.uncommitted, changes.uncommitted), (.committed, changes.committed)]
            let documents = sections.flatMap { section -> [ReviewDocument] in
                guard expansion(of: section.compare == .uncommitted ? "uncommitted" : "committed", root: shownRepo).wrappedValue else { return [] }

                return self.documents(section.files, compare: section.compare, in: target, root: root)
            }
            return documents + graphFileOrder + filesOrder
        }

        let own = changes.flatMap { changes in
            repositoryExpansion(ownRoot).wrappedValue ? documents(changes.uncommitted, compare: .uncommitted, in: model, root: nil) + documents(changes.committed, compare: .committed, in: model, root: nil) : nil
        } ?? []
        let others = extras.flatMap { extra -> [ReviewDocument] in
            guard repositoryExpansion(extra.repository.root).wrappedValue, let changes = extra.model.changes else { return [] }

            return documents(changes.uncommitted, compare: .uncommitted, in: extra.model, root: extra.repository.root) + documents(changes.committed, compare: .committed, in: extra.model, root: extra.repository.root)
        }
        return own + graphFileOrder + filesOrder + others
    }

    private func documents(_ files: [ReviewFile], compare: ReviewCompare, in model: ReviewModel, root: String?) -> [ReviewDocument] {
        guard changesAsTree else { return files.map { ReviewDocument(path: $0.path, compare: compare, root: root) } }

        return ReviewFileTree.compactNodes(files.map(\.path)).flatMap { leaves(of: $0, compare: compare, root: root, in: model) }
    }

    private func leaves(of node: ReviewFileTree, compare: ReviewCompare?, root: String?, in model: ReviewModel) -> [ReviewDocument] {
        guard let children = node.children else { return [ReviewDocument(path: node.path, compare: compare, root: root)] }

        let isExpanded = compare.map { !model.collapsedChangeFolders.contains(ReviewDocument(path: node.path, compare: $0)) } ?? model.expandedFolders.contains(node.path)
        return isExpanded ? children.flatMap { leaves(of: $0, compare: compare, root: root, in: model) } : []
    }

    private func open(_ document: ReviewDocument) {
        if let link = document.pullRequestLink {
            let extra = store.shownReviewPullRequests[sessionID]?[link] == nil ? extras.first { $0.repository.root == shownRepo } : nil
            (extra?.model ?? model).open(document)
            return
        }
        let target = document.root.flatMap { store.reviewModels[Store.reviewKey(sessionID, root: $0)] } ?? model
        let plain = ReviewDocument(path: document.path, compare: document.compare)
        target.open(plain.compare == nil ? target.workingDocument(plain.path) : plain)
    }

    private var selection: ReviewDocument? {
        let active = store.reviewModel ?? model
        return active.selectedDocument.map { document in
            if document.pullRequestLink != nil { return document }

            return ReviewDocument(path: document.path, compare: document.compare, root: active === model ? nil : store.activeReviewRoots[sessionID])
        }
    }

    @ViewBuilder
    private func changeSections(_ changes: ReviewChanges, in model: ReviewModel, root: String?) -> some View {
        if changes.uncommitted.isEmpty, changes.committed.isEmpty, !changes.isDefaultBranch, let base = changes.base {
            Text("No changes, \(changes.branch) matches \(base)")
                .foregroundStyle(theme.secondary)
                .reviewRow(bottom: 6)
        }
        if !changes.uncommitted.isEmpty {
            SidebarSection(title: "Uncommitted", help: "HEAD to the working tree", count: changes.uncommitted.count, isExpanded: expansion(of: "uncommitted", root: shownRepo)) {
                changeRows(changes.uncommitted, compare: .uncommitted, changes: changes, in: model, root: root)
            }
        }
        if !changes.committed.isEmpty {
            SidebarSection(title: "Committed", help: "\(changes.base ?? "The base") to HEAD", count: changes.committed.count, isExpanded: expansion(of: "committed", root: shownRepo)) {
                changeRows(changes.committed, compare: .committed, changes: changes, in: model, root: root)
            }
        }
    }

    @ViewBuilder
    private func changeRows(_ files: [ReviewFile], compare: ReviewCompare, changes: ReviewChanges, in model: ReviewModel, root: String?) -> some View {
        if changesAsTree {
            ForEach(ReviewFileTree.compactNodes(files.map(\.path))) { node in
                ReviewFileNode(node: node, compare: compare, changes: changes, model: model, root: root)
            }
        } else {
            ForEach(files, id: \.path) { file in
                let document = ReviewDocument(path: file.path, compare: compare, root: root)
                ReviewChangeRow(file: file, model: model)
                    .reviewRow()
                    .modifier(ReviewRowChrome(document: document, model: model, opensWorkingFile: file.status != .deleted))
                    .id(document)
            }
        }
    }

    private func shownPullRequest(root: String?, branch: String) -> (repository: String, pullRequest: PullRequest?)? {
        let target = root.flatMap { store.reviewModels[Store.reviewKey(sessionID, root: $0)] } ?? model
        guard target.changes?.branch == branch else { return nil }

        return store.shownReviewPullRequest(for: target, sessionID: sessionID, root: root, branchOnly: !isStacked)
    }

    private func branchCard(_ changes: ReviewChanges, _ status: ReviewBranchStatus) -> some View {
        let shown = shownPullRequest(root: nil, branch: changes.branch)
        let detail = shown?.pullRequest.flatMap { model.pullRequestDetails[$0.number] }
        return ReviewBranchCard(changes: changes, status: status, pullRequest: shown.map(\.pullRequest), repository: shown?.repository, detail: detail, isClaudeLive: store.liveBySession[sessionID] != nil, createPullRequest: { store.createPullRequest(sessionID: sessionID, model: model) }, showThreads: { showThreadSection(ownRoot, detail: detail) })
    }

    private var allExtras: [(repository: ReviewRepository, model: ReviewModel)] {
        (store.reviewRepositories[sessionID] ?? []).compactMap { repository in
            store.reviewModels[Store.reviewKey(sessionID, root: repository.root)].map { (repository, $0) }
        }
    }

    private var extras: [(repository: ReviewRepository, model: ReviewModel)] {
        allExtras.filter { extra in
            guard extra.repository.isEdited, let changes = extra.model.changes else { return true }

            return !changes.uncommitted.isEmpty || !changes.committed.isEmpty || !extra.model.comments.isEmpty
        }
    }

    private var sessionFilesModel: ReviewModel? { store.reviewModels[Store.reviewKey(sessionID, root: Store.sessionFilesRoot)] }

    private var sessionFiles: [String] {
        guard sessionFilesModel != nil else { return [] }

        let listed = Set(owners.flatMap { owner in owner.model.changes.map { changes in (changes.uncommitted + changes.committed).map { URL(filePath: changes.root).resolvingSymlinksInPath().path + "/" + $0.path } } ?? [] })
        return (store.editedFiles[sessionID] ?? []).filter { !listed.contains($0) }
            .map { $0.hasPrefix(Store.resolvedHome + "/") ? "~" + $0.dropFirst(Store.resolvedHome.count) : String($0.dropFirst()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var sessionFileOrder: [ReviewDocument] {
        guard shownRepo == nil, let filesModel = sessionFilesModel, expansion(of: "sessionFiles").wrappedValue else { return [] }

        let files = sessionFiles
        guard changesAsTree else { return files.map(sessionFileDocument) }

        return ReviewFileTree.compactNodes(files).flatMap { sessionLeaves(of: $0, in: filesModel) }
    }

    private func sessionLeaves(of node: ReviewFileTree, in model: ReviewModel) -> [ReviewDocument] {
        guard let children = node.children else { return [sessionFileDocument(node.path)] }

        return model.collapsedSessionFolders.contains(node.path) ? [] : children.flatMap { sessionLeaves(of: $0, in: model) }
    }

    @ViewBuilder private var sessionFilesSection: some View {
        let files = sessionFiles
        if shownRepo == nil, let filesModel = sessionFilesModel, !files.isEmpty {
            SidebarSection(title: "Edited by Session", help: "Files this session wrote or edited that no changes list shows", count: files.count, isExpanded: expansion(of: "sessionFiles")) {
                if changesAsTree {
                    ForEach(ReviewFileTree.compactNodes(files)) { SessionFileNode(node: $0, model: filesModel) }
                } else {
                    ForEach(files, id: \.self) { path in
                        SessionFileRow(path: path)
                            .reviewRow(top: 6, bottom: 6)
                            .modifier(ReviewRowChrome(document: sessionFileDocument(path), model: filesModel))
                            .id(sessionFileDocument(path))
                    }
                }
            }
        }
    }

    private var owners: [(model: ReviewModel, repository: ReviewRepository?)] {
        [(model, nil)] + allExtras.map { ($0.model, $0.repository) }
    }

    private var noticeOwner: ReviewModel? { owners.first { $0.model.notice != nil }?.model }

    private var isStacked: Bool { store.task(containing: sessionID) != nil || !extras.isEmpty }

    private var extraStates: [String] {
        extras.map { "\($0.repository.root)|\($0.model.changes?.branch ?? "")|\(store.pullRequests(inRoot: $0.repository.root, of: sessionID, branch: $0.model.changes?.branch).map { "\($0.number)\($0.baseRefName ?? "")" })" }
    }

    private func prepare(_ repository: ReviewRepository, _ model: ReviewModel) async {
        if model.changes == nil { await model.load() }
        guard let branch = model.changes?.branch else { return }

        let key = store.pullRequestBranch(inRoot: repository.root, branch: branch)
        let found = key.flatMap { store.pullRequests[$0] ?? nil }
        if let shown = shownPullRequest(root: repository.root, branch: branch), let number = shown.pullRequest?.number, model.pullRequestDetails[number] == nil { await model.loadPullRequestDetail(repository: shown.repository, number: number) }
        if let key, store.pullRequests[key] == nil, Snapshot.output == nil { await store.fetchPullRequests([key]) }
        let base = found?.baseRefName.map { (branch: branch, base: $0) }
        guard base?.branch != model.pullRequestBase?.branch || base?.base != model.pullRequestBase?.base else { return }

        model.pullRequestBase = base
        await model.load()
    }

    private func repositoryExpansion(_ key: String) -> Binding<Bool> {
        Binding {
            !store.collapsedReviewRepositories.contains(key)
        } set: { expanded in
            if expanded { store.collapsedReviewRepositories.remove(key) } else { store.collapsedReviewRepositories.insert(key) }
        }
    }

    private func taskCard(_ task: StoredTask) -> some View {
        let ownRoot = store.repositoryRoot(ofSession: sessionID) ?? model.folder
        let members = task.sessionIDs.compactMap { store.sessionsByID[$0] }.sorted { $0.lastPrompt > $1.lastPrompt }
        return ReviewTaskHeader(
            title: store.title(of: task),
            issue: task.issue,
            members: members,
            currentID: sessionID,
            pullRequestCount: (model.changes.map { store.pullRequests(inRoot: nil, of: sessionID, branch: $0.branch).count } ?? 0) + extras.reduce(0) { $0 + store.pullRequests(inRoot: $1.repository.root, of: sessionID, branch: $1.model.changes?.branch).count },
            repositoryCount: Set(members.compactMap { store.repositoryRoot(ofSession: $0.id) } + [ownRoot] + extras.map(\.repository.root)).count,
            showsRepositories: extras.isEmpty,
            isExpanded: Binding(get: { store.expandedReviewTasks.contains(task.id) }, set: { if $0 { store.expandedReviewTasks.insert(task.id) } else { store.expandedReviewTasks.remove(task.id) } }),
            activate: { store.activate(.session($0)) }
        )
    }

    private func extraCard(_ extra: (repository: ReviewRepository, model: ReviewModel), _ changes: ReviewChanges) -> some View {
        let found = shownPullRequest(root: extra.repository.root, branch: changes.branch)
        let detail = found?.pullRequest.flatMap { extra.model.pullRequestDetails[$0.number] }
        return ReviewBranchCard(changes: changes, status: extra.model.status ?? .unknown, pullRequest: found.map(\.pullRequest), repository: found?.repository, detail: detail, isClaudeLive: store.liveBySession[sessionID] != nil, createPullRequest: nil, showThreads: { showThreadSection(extra.repository.root, detail: detail) })
    }

    private var ownRoot: String { store.repositoryRoot(ofSession: sessionID) ?? model.folder }

    private var shownRepo: String? {
        guard let task = store.task(containing: sessionID), !extras.isEmpty else { return nil }

        let picked = store.reviewRepoTabs[task.id] ?? ownRoot
        guard picked != "all" else { return nil }

        return extras.contains { $0.repository.root == picked } ? picked : ownRoot
    }

    private func repoTabs(_ task: StoredTask) -> some View {
        let own = model.changes.map { changes in
            ReviewRepoRow(id: ownRoot, name: URL(filePath: ownRoot).lastPathComponent, branch: changes.branch, base: pullRequestBase(changes, root: nil), pullRequest: shownPullRequest(root: nil, branch: changes.branch)?.pullRequest)
        } ?? ReviewRepoRow(id: ownRoot, name: URL(filePath: ownRoot).lastPathComponent, branch: nil, base: nil, pullRequest: nil)
        let others = extras.map { extra in
            ReviewRepoRow(id: extra.repository.root, name: extra.repository.name, branch: extra.model.changes?.branch, base: extra.model.changes.flatMap { pullRequestBase($0, root: extra.repository.root) }, pullRequest: extra.model.changes.flatMap { shownPullRequest(root: extra.repository.root, branch: $0.branch)?.pullRequest })
        }
        return ReviewRepoRows(rows: [own] + others + [ReviewRepoRow(id: "all", name: "All repos", branch: nil, base: nil, pullRequest: nil)], selection: Binding(get: { shownRepo ?? "all" }, set: { store.reviewRepoTabs[task.id] = $0 }))
    }

    private func pullRequestBase(_ changes: ReviewChanges, root: String?) -> String? {
        shownPullRequest(root: root, branch: changes.branch)?.pullRequest?.baseRefName ?? (changes.isDefaultBranch ? nil : changes.base)
    }

    @ViewBuilder
    private func repoRows(_ root: String) -> some View {
        if root == ownRoot, let changes = model.changes {
            threadSection(in: model, root: nil)
            changeSections(changes, in: model, root: nil)
        } else if let extra = extras.first(where: { $0.repository.root == root }), let changes = extra.model.changes {
            threadSection(in: extra.model, root: root)
            changeSections(changes, in: extra.model, root: root)
        } else {
            Text("Loading changes…")
                .foregroundStyle(theme.secondary)
                .reviewRow(bottom: 6)
        }
    }

    @ViewBuilder
    private func stackedSections(_ changes: ReviewChanges?) -> some View {
        if let changes {
            let title = URL(filePath: ownRoot).lastPathComponent
            SidebarSection(isExpanded: repositoryExpansion(ownRoot)) {
                branchCard(changes, model.status ?? .unknown)
                    .reviewRow(bottom: 6)
                stackedRows(changes, in: model, root: nil)
            } header: { expansion in
                ReviewRepositoryHeader(title: title, help: ownRoot, isExpanded: expansion) {
                    ReviewRepositoryAccessory(branch: nil, base: nil, pullRequests: store.pullRequests(inRoot: nil, of: sessionID, branch: changes.branch), hiding: expansion.wrappedValue ? shownPullRequest(root: nil, branch: changes.branch)?.pullRequest?.number : nil)
                }
            }
            commitsSection(changes)
            filesSection(changes)
        }
        ForEach(extras, id: \.repository.root) { extra in
            SidebarSection(isExpanded: repositoryExpansion(extra.repository.root)) {
                if let changes = extra.model.changes {
                    extraCard(extra, changes)
                        .reviewRow(bottom: 6)
                    stackedRows(changes, in: extra.model, root: extra.repository.root)
                } else {
                    Text(extra.model.error == nil ? "Loading changes…" : "Can’t read changes")
                        .foregroundStyle(theme.secondary)
                        .reviewRow(bottom: 6)
                }
            } header: { expansion in
                ReviewRepositoryHeader(title: extra.repository.name, help: extra.repository.folder, isExpanded: expansion) {
                    ReviewRepositoryAccessory(branch: extra.model.changes?.branch, base: extra.model.changes.flatMap { $0.isDefaultBranch ? nil : $0.base }, pullRequests: store.pullRequests(inRoot: extra.repository.root, of: sessionID, branch: extra.model.changes?.branch), hiding: expansion.wrappedValue ? extra.model.changes.flatMap { shownPullRequest(root: extra.repository.root, branch: $0.branch) }?.pullRequest?.number : nil)
                }
            }
        }
    }

    @ViewBuilder
    private func stackedRows(_ changes: ReviewChanges, in model: ReviewModel, root: String?) -> some View {
        threadSection(in: model, root: root)
        if changes.uncommitted.isEmpty, changes.committed.isEmpty, !changes.isDefaultBranch, let base = changes.base {
            Text("No changes, \(changes.branch) matches \(base)")
                .foregroundStyle(theme.secondary)
                .reviewRow(bottom: 6)
        }
        if !changes.uncommitted.isEmpty {
            ReviewSubheading(title: "Uncommitted", count: changes.uncommitted.count)
            changeRows(changes.uncommitted, compare: .uncommitted, changes: changes, in: model, root: root)
        }
        if !changes.committed.isEmpty {
            ReviewSubheading(title: "Committed", count: changes.committed.count)
            changeRows(changes.committed, compare: .committed, changes: changes, in: model, root: root)
        }
    }

    private func panel(_ changes: ReviewChanges?) -> some View {
        VStack(spacing: 0) {
            if let changes {
                header(changes)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    GlassCapsule {
                        treeToggle(changes)
                        refreshButton
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            movedFolderNotice
            inspector(changes)
            commentsBar
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var movedFolderNotice: some View {
        if let movedFolder = model.movedFolder {
            Label("This session moved to \((movedFolder as NSString).abbreviatingWithTildeInPath). Save or undo your edits and send or delete your comments to follow it.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(theme.needsYou)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ReviewInset.content)
                .padding(.vertical, 6)
        }
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
            .disabled(model.isLoading)
            .help("Refresh")
    }

    private func movePersistedPanelTab() {
        switch UserDefaults.standard.string(forKey: "reviewPanelTab") {
        case "preview": model.showPreview()

        case "comments": model.showsCommentList = true

        case "files": expansion(of: "files", defaultExpanded: false).wrappedValue = true

        case "graph":
            expansion(of: "commits", defaultExpanded: false).wrappedValue = true
            expansion(of: "history", defaultExpanded: false).wrappedValue = true

        default: return
        }
        if store.persistsTabs { UserDefaults.standard.removeObject(forKey: "reviewPanelTab") }
    }

    private var commentCount: Int { owners.reduce(0) { $0 + $1.model.comments.count } }

    private func inspector(_ changes: ReviewChanges?) -> some View {
        VStack(spacing: 0) {
            if let task = store.task(containing: sessionID) {
                VStack(spacing: 0) {
                    taskCard(task)
                    if !extras.isEmpty { repoTabs(task) }
                }
                .background(theme.foreground.opacity(0.05), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.foreground.opacity(0.1)))
                .padding(.horizontal, ReviewInset.fill)
                .padding(.bottom, 8)
            }
            changesList(changes)
        }
    }

    private func changesList(_ changes: ReviewChanges?) -> some View {
        let changeFolders = changesAsTree ? ((changes.map { [$0] } ?? []) + extras.compactMap(\.model.changes)).flatMap { changes in
            [changes.uncommitted, changes.committed].map { ReviewFileTree.compactNodes($0.map(\.path)).flatMap(\.folderPaths) }
        } + [ReviewFileTree.compactNodes(sessionFiles).flatMap(\.folderPaths)] : nil
        return list(name: "review", order: changeOrder(changes)) {
            if isStacked {
                pullRequestSection(changes)
                if shownRepo != nil || !store.shownReviewPullRequests[sessionID, default: [:]].isEmpty {
                    sessionPullRequestSection(changes)
                }
                if let shownRepo {
                    repoRows(shownRepo)
                    if shownRepo == ownRoot, let changes {
                        commitsSection(changes)
                        filesSection(changes)
                    }
                } else {
                    stackedSections(changes)
                }
            } else {
                if let issue = reviewIssue {
                    ReviewIssueCard(issue: issue)
                        .reviewRow(bottom: 6)
                }
                if let changes { branchPullRequestArea(changes) }
                sessionPullRequestSection(changes)
                if let changes {
                    threadSection(in: model, root: nil)
                    changeSections(changes, in: model, root: nil)
                    commitsSection(changes)
                    filesSection(changes)
                }
            }
            sessionFilesSection
        }
        .id(changeFolders)
        .id(model.tree.flatMap(\.folderPaths))
        .id([shownRepo] + extras.map(\.repository.root))
        .onChange(of: (store.reviewModel ?? model).selectedDocument, initial: true) { _, document in
            guard let document, let compare = document.compare, !compare.isHistorical, let active = store.reviewModel else { return }

            active.collapsedChangeFolders = active.collapsedChangeFolders.filter { $0.compare != compare || !document.path.hasPrefix($0.path + "/") }
        }
    }

    private var reviewIssue: ClosingIssue? {
        if let issue = pullRequest?.pullRequest?.closingIssues.first { return issue }
        guard let issue = store.task(containing: sessionID)?.issue
            ?? store.tasks.tasks.first(where: { $0.sessionIDs == [sessionID] })?.issue
            ?? store.sessionsByID[sessionID]?.issueRefs.first
        else { return nil }

        return ClosingIssue(ref: issue, title: "", state: store.state(of: issue))
    }

    @ViewBuilder
    private func branchPullRequestArea(_ changes: ReviewChanges) -> some View {
        if let shown = pullRequest, let pullRequest = shown.pullRequest {
            let entry = ReviewPullRequest(pullRequest: pullRequest, repository: shown.repository, root: changes.root)
            let detail = model.pullRequestDetails[pullRequest.number]
            ReviewPullRequestCard(entry: entry, model: model, branch: pullRequest.headRefName ?? changes.branch, base: pullRequest.baseRefName ?? changes.base, detail: detail) {
                showThreadSection(ownRoot, detail: detail)
            }
            .reviewRow(bottom: 6)
            if let key = branchStackKey, let stack = model.pullRequestStacks[key], stack.parent != nil || !stack.children.isEmpty {
                SidebarSection(title: "Stack", help: "Pull requests based on each other", count: 1 + (stack.parent == nil ? 0 : 1) + stack.children.count, isExpanded: expansion(of: "stack")) {
                    ReviewPullRequestStackRows(branch: entry, stack: stack, model: model)
                }
            }
        } else {
            ReviewPullRequestEmpty(changes: changes, status: model.status ?? .unknown, sessionID: sessionID, model: model)
                .reviewRow(bottom: 6)
        }
    }

    @ViewBuilder
    private func pullRequestSection(_ changes: ReviewChanges?) -> some View {
        if shownRepo == ownRoot, let changes {
            let shown = shownPullRequest(root: nil, branch: changes.branch)
            SidebarSection(title: shown?.pullRequest == nil ? changes.branch : "Pull Request", help: "The branch’s pull request and checks", isExpanded: expansion(of: "pullRequest")) {
                branchCard(changes, model.status ?? .unknown)
                    .reviewRow(bottom: 6)
            }
        } else if let shownRepo, let extra = extras.first(where: { $0.repository.root == shownRepo }), let changes = extra.model.changes {
            let shown = shownPullRequest(root: extra.repository.root, branch: changes.branch)
            SidebarSection(title: shown?.pullRequest == nil ? changes.branch : "Pull Request", help: "The branch’s pull request and checks", isExpanded: expansion(of: "pullRequest")) {
                extraCard(extra, changes)
                    .reviewRow(bottom: 6)
            }
        }
    }

    private func commitsSection(_ changes: ReviewChanges) -> some View {
        let commits = branchCommits
        let history = expansion(of: "history", defaultExpanded: false)
        return SidebarSection(title: "Commits", help: "Branch commits and repository history", count: commits.isEmpty ? nil : commits.count, isExpanded: expansion(of: "commits", defaultExpanded: false)) {
            ForEach(commits, id: \.sha) { commit in
                ReviewBranchCommitRow(commit: commit)
                    .font(.callout)
                    .lineLimit(1)
                    .reviewRow()
            }
            if !changes.isDefaultBranch {
                SidebarSectionHeader<EmptyView, EmptyView>(title: "History", help: "Browse repository history", count: nil, isExpanded: history, accessory: nil, replacementTitle: nil)
                    .reviewRow(leading: ReviewInset.tree)
            }
            if changes.isDefaultBranch || history.wrappedValue { ReviewGraphRows(model: model, changes: changes) }
        }
    }

    private func filesSection(_ changes: ReviewChanges) -> some View {
        SidebarSection(title: "Files", help: "Browse the repository’s files", isExpanded: expansion(of: "files", defaultExpanded: false)) {
            ForEach(model.tree) { ReviewFileNode(node: $0, compare: nil, changes: changes, model: model) }
        }
    }

    private func sessionPullRequests(in changes: ReviewChanges?) -> [(root: String?, entries: [ReviewPullRequest], model: ReviewModel)] {
        let shown = changes.flatMap { shownPullRequest(root: nil, branch: $0.branch) }
        let entries = store.sessionReviewPullRequests(of: sessionID, changes: !isStacked || shownRepo == ownRoot ? changes : nil, excluding: shown?.pullRequest?.number)
        guard let root = shownRepo, let extra = extras.first(where: { $0.repository.root == root }), let changes = extra.model.changes,
              let repository = store.pullRequestBranch(inRoot: root, branch: changes.branch)?.repository else { return [(nil, entries, model)] }

        let branchNumber = shownPullRequest(root: root, branch: changes.branch)?.pullRequest?.number
        let linked = store.pullRequests(inRoot: root, of: sessionID, branch: changes.branch).compactMap { pullRequest -> ReviewPullRequest? in
            let link = PullRequestLink(repository: repository.lowercased(), number: pullRequest.number)
            guard pullRequest.number != branchNumber, store.shownReviewPullRequests[sessionID]?[link] == nil else { return nil }

            return ReviewPullRequest(location: ReviewPullRequestLocation(link: link, root: changes.root), pullRequest: pullRequest)
        }
        return [(root, linked, extra.model), (nil, entries, model)]
    }

    private func sessionPullRequestSection(_ changes: ReviewChanges?) -> some View {
        let groups = sessionPullRequests(in: changes)
        let count = groups.reduce(0) { $0 + $1.entries.count }
        return SidebarSection(isExpanded: count == 0 ? .constant(false) : expansion(of: "otherPullRequests", defaultExpanded: false)) {
            ForEach(groups, id: \.root) { group in
                ReviewOtherPullRequests(entries: group.entries, model: group.model)
            }
        } header: { expansion in
            SidebarSectionHeader(title: "Session pull requests", help: "Pull requests linked to this session or added to Review", count: count == 0 ? nil : count, isExpanded: expansion) {
                Button("Add a pull request to Review", systemImage: "plus") { AppAction.showPullRequestInReview.perform(on: store) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add a pull request to Review")
            }
        }
    }

    private var hasOwnRepository: Bool {
        model.changes != nil && (shownRepo == nil || shownRepo == ownRoot)
    }

    private func expansion(of id: String, defaultExpanded: Bool = true, root: String? = nil) -> Binding<Bool> {
        let id = root.map { id + ":" + $0.replacing("%", with: "%25").replacing(",", with: "%2C") } ?? id
        return Binding {
            let sections = collapsedSections.split(separator: ",")
            if let expanded = model.expansionOverrides[id] { return expanded }
            if sections.contains(where: { $0 == "+" + id }) { return true }
            return defaultExpanded && !sections.contains { $0 == id }
        } set: { expanded in
            if model.expansionOverrides[id] != nil || !store.persistsTabs {
                model.expansionOverrides[id] = expanded
                return
            }
            let others = collapsedSections.split(separator: ",").filter { $0 != id && $0 != "+" + id }.map(String.init)
            if expanded, !defaultExpanded {
                collapsedSections = (others + ["+" + id]).joined(separator: ",")
            } else {
                collapsedSections = (expanded ? others : others + [id]).joined(separator: ",")
            }
        }
    }

    private func showThreadSection(_ root: String, detail: PullRequestDetail?) {
        expansion(of: "reviewThreads", defaultExpanded: isStacked || (detail?.unresolvedThreads ?? 0) > 0).wrappedValue = true
        threadSectionScroll = "reviewThreads:" + root
    }

    @ViewBuilder
    private func threadSection(in model: ReviewModel, root: String?) -> some View {
        if let shown = store.shownReviewPullRequest(for: model, sessionID: sessionID, root: root, branchOnly: !isStacked)?.pullRequest,
           let detail = model.pullRequestDetails[shown.number], !detail.threads.isEmpty {
            let expanded = expansion(of: "reviewThreads", defaultExpanded: isStacked || detail.unresolvedThreads > 0)
            let header = SidebarSectionHeader<EmptyView, EmptyView>(title: "Review Threads", help: "Threads on the pull request", count: detail.threads.count, isExpanded: expanded, accessory: nil, replacementTitle: nil)
                .id("reviewThreads:" + (root ?? ownRoot))
            if isStacked, shownRepo == nil {
                header.reviewRow()
                if expanded.wrappedValue { ReviewThreadRows(threads: detail.threads, open: model.open) }
            } else {
                SidebarSection(isExpanded: expanded) {
                    ReviewThreadRows(threads: detail.threads, open: model.open)
                } header: { _ in
                    header
                }
            }
        }
    }

    @ViewBuilder private var commentsBar: some View {
        if commentCount > 0 {
            VStack(spacing: 0) {
                if model.showsCommentList {
                    commentList
                        .frame(maxHeight: 220)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }
                HStack {
                    Button {
                        model.showsCommentList.toggle()
                    } label: {
                        Label("Comments \(commentCount)", systemImage: model.showsCommentList ? "chevron.down" : "chevron.up")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondary)
                    .help(model.showsCommentList ? "Hide the comment list" : "Show the comment list")
                    Spacer(minLength: 4)
                    Button(action: sendComments) {
                        Text("Send \(commentCount) \(commentCount == 1 ? "Comment" : "Comments")")
                            .lineLimit(1)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .layoutPriority(1)
                    .help("Paste every pending comment into the session")
                }
                .padding(10)
                .padding(.leading, ReviewInset.content - 10)
            }
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var commentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(owners.flatMap { owner in owner.model.comments.map { (owner: owner, comment: $0) } }, id: \.comment.id) { owner, comment in
                    let target = store.shownReviewPullRequest(for: owner.model, sessionID: sessionID, root: owner.repository?.root, branchOnly: !isStacked)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comment.element.map { "Preview \($0.selector)" } ?? "\(owner.repository.map { "\($0.name):" } ?? "")\(comment.path):\(comment.endLine > comment.line ? "\(comment.line)-\(comment.endLine)" : "\(comment.line)")\(comment.compare == .committed ? ", committed" : "")")
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(comment.text)
                                .lineLimit(3)
                        }
                        .contentShape(.rect)
                        .onTapGesture { open(comment, in: owner.model) }
                        Spacer(minLength: 4)
                        Button("Open", systemImage: "arrow.up.forward.square") { open(comment, in: owner.model) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help(comment.element == nil ? "Open in the diff" : "Open Preview")
                        if comment.element == nil {
                            Button {
                                guard let target, let number = target.pullRequest?.number else { return }

                                Task { await owner.model.sendToPullRequest(comment, repository: target.repository, number: number) }
                            } label: {
                                Label { Text("Add to Pull Request Review") } icon: { OcticonImage(.pullRequest) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(owner.model.isWritingPullRequest || target?.pullRequest.flatMap { owner.model.pullRequestDetails[$0.number]?.id } == nil)
                            .help("Add to your pending review, then submit the review on GitHub")
                        }
                        Button("Delete Comment", systemImage: "xmark") {
                            owner.model.comments.removeAll { $0.id == comment.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(12)
        }
    }

    private func open(_ comment: ReviewComment, in model: ReviewModel) {
        guard comment.element == nil else {
            model.showPreview()
            return
        }

        model.open(ReviewDocument(path: comment.path, compare: comment.compare))
        model.editingComment = comment.id
    }

    private var pullRequest: (repository: String, pullRequest: PullRequest?)? {
        guard let changes = model.changes else { return nil }

        if !isStacked { return shownPullRequest(root: nil, branch: changes.branch) }

        return store.pullRequest(in: store.sessionsByID[sessionID]?.checkout ?? model.folder, branch: changes.branch)
    }

    private var branchStackKey: ReviewPullRequestStackKey? {
        guard !isStacked, let shown = pullRequest, let pullRequest = shown.pullRequest,
              let head = pullRequest.headRefName ?? model.changes?.branch,
              let base = pullRequest.baseRefName ?? model.changes?.defaultBase
        else { return nil }

        return ReviewPullRequestStackKey(repository: shown.repository, head: head, base: base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base)
    }

    private func loadPullRequestDetail() async {
        guard let pullRequest = model.changes.flatMap({ shownPullRequest(root: nil, branch: $0.branch) }), let number = pullRequest.pullRequest?.number else { return }

        await model.loadPullRequestDetail(repository: pullRequest.repository, number: number, stack: branchStackKey)
    }

    private func header(_ changes: ReviewChanges) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(changes.isDefaultBranch || changes.base == nil ? "\(changes.branch), uncommitted only" : changes.branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 48, alignment: .leading)
                if !changes.isDefaultBranch, let base = changes.base {
                    baseMenu(base, candidates: changes.bases)
                        .layoutPriority(1)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(theme.branch)
            Spacer(minLength: 4)
            panelWarnings(changes)
            GlassCapsule {
                treeToggle(changes)
                refreshButton
            }
        }
        .font(.callout)
        .padding(.leading, ReviewInset.content)
        .padding(.trailing, ReviewInset.fill)
        .padding(.vertical, 6)
    }

    private func baseMenu(_ base: String, candidates: [ReviewBase]) -> some View {
        let pullRequestBase = pullRequest?.pullRequest?.baseRefName
        return Menu {
            Picker("Compare Against", selection: Binding(get: { base }, set: { model.pickBase($0) })) {
                ForEach(candidates, id: \.ref) { candidate in
                    let isPullRequestBase = pullRequestBase.map { candidate.ref == $0 || candidate.ref == "origin/\($0)" } ?? false
                    Text("\(candidate.ref) · \(candidate.distance) \(candidate.distance == 1 ? "commit" : "commits")\(isPullRequestBase ? " · PR base" : "")")
                        .tag(candidate.ref)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text("→ \(base)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Compare against…")
    }

    @ViewBuilder
    private func panelWarnings(_ changes: ReviewChanges) -> some View {
        if let fetchError = changes.fetchError {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.needsYou)
                .help("Couldn’t fetch. Comparing local refs. \(fetchError)")
                .accessibilityLabel("Fetch failed")
        }
        if let error = model.error {
            let failure = failure(error)
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.needsYou)
                .help("Couldn’t refresh. Showing the last changes. \(failure.detail ?? failure.description)")
                .accessibilityLabel("Refresh failed")
        }
    }

    @ViewBuilder
    private func treeToggle(_ changes: ReviewChanges?) -> some View {
        if changes.map({ !$0.uncommitted.isEmpty || !$0.committed.isEmpty }) == true || !sessionFiles.isEmpty || extras.contains(where: { $0.model.changes.map { !$0.uncommitted.isEmpty || !$0.committed.isEmpty } == true }) {
            Button(changesAsTree ? "View as List" : "View as Tree", systemImage: changesAsTree ? "list.bullet" : "list.bullet.indent") { changesAsTree.toggle() }
                .help(changesAsTree ? "View as List" : "View as Tree")
        }
    }

    private func refresh() {
        Task {
            await store.refreshReview()
            guard store.primaryReviewModel === model else { return }

            if let repository = pullRequest?.repository, let branch = model.changes?.branch { await store.fetchPullRequests([PullRequestBranch(repository: repository, branch: branch)]) }
            await loadPullRequestDetail()
        }
    }

    private func failure(_ error: any Error) -> (title: String, symbol: String, description: String, detail: String?) {
        let folder = (model.folder as NSString).abbreviatingWithTildeInPath
        if case ReviewGitError.notARepository = error { return ("No Git Repository", "folder", "\(folder) isn’t in a git repository, so there are no changes to review.", nil) }
        if case ReviewGitError.folderNotFound = error { return ("Folder Not Found", "questionmark.folder", "\(folder) doesn’t exist anymore.", nil) }
        if case let ReviewGitError.gitNotFound(message) = error { return ("Git Not Found", "exclamationmark.triangle", "Review needs git. Install the Command Line Tools by running xcode-select --install in Terminal.", message) }
        return ("Can’t Read Changes", "exclamationmark.triangle", "Git couldn’t read the changes in \(folder).", ReviewModel.describe(error))
    }

    private func sendComments() {
        let prompt = owners.filter { !$0.model.comments.isEmpty }.map { owner in
            ReviewComment.prompt(for: owner.model.comments, branch: owner.model.changes?.branch ?? "HEAD", base: owner.model.changes.flatMap { $0.isDefaultBranch ? nil : $0.base } ?? "HEAD", repository: owner.repository.map { ($0.name, $0.root) })
        }.joined(separator: "\n\n")
        guard store.sendReviewPrompt(prompt, sessionID: sessionID, noticeIn: model) else { return }

        for owner in owners { owner.model.comments = [] }
    }
}

extension Store {
    func createPullRequest(sessionID: String, model: ReviewModel) {
        let base = model.changes.flatMap { $0.base == $0.defaultBase ? nil : $0.base }.map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
        let prompt = base.map { "Push this branch and open a pull request for it against \($0) with gh (--base \($0))." } ?? "Push this branch and open a pull request for it with gh."
        guard liveBySession[sessionID] != nil, let terminal = tab(forSession: sessionID)?.terminal, terminal.paste(text: prompt) else {
            model.notice = "Claude isn’t running in this tab"
            return
        }

        terminal.requestFocus()
    }
}

private struct ReviewRowChrome: ViewModifier {
    let document: ReviewDocument?
    let model: ReviewModel
    var followsFilePath = false
    var opensWorkingFile = false
    @State private var isHovering = false
    @Environment(Store.self) private var store

    func body(content: Content) -> some View {
        let isSelected = document.map { document in
            let matches = model.selectedDocument.map { selected in
                selected.path == document.path && (selected.compare == document.compare || (followsFilePath && selected.compare?.isHistorical != true))
            } ?? false
            return (store.reviewModel.map { $0 === model } ?? true) && matches
        } ?? false
        content
            .contentShape(.rect)
            .listRowSeparator(.hidden)
            .onTapGesture {
                guard let document else { return }

                if opensWorkingFile, NSEvent.modifierFlags.contains(.command) {
                    model.open(ReviewDocument(path: document.path, compare: nil))
                    return
                }
                model.open(document.compare == nil ? model.workingDocument(document.path) : ReviewDocument(path: document.path, compare: document.compare))
                if NSApp.currentEvent?.clickCount == 2 { model.selectedTabID.map(model.keep) }
            }
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .listRowBackground(RowFill(opacity: isSelected ? 0.18 : isHovering ? 0.06 : 0, color: isSelected ? .accentColor : .primary, cornerRadius: 6, verticalInset: 1))
    }
}

private func sessionFileDocument(_ path: String) -> ReviewDocument {
    let absolute = path.hasPrefix("~") ? Store.resolvedHome + path.dropFirst() : "/" + path
    return ReviewDocument(path: String(absolute.dropFirst()), compare: nil, root: Store.sessionFilesRoot)
}

private struct SessionFileRow: View {
    let path: String
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let folder = (path as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Text((path as NSString).lastPathComponent)
                .font(.subheadline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(folder.hasPrefix("~") ? folder : "/" + folder)
                .font(.caption2.monospaced())
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(-1)
        }
        .help(path.hasPrefix("~") ? path : "/" + path)
    }
}

private struct SessionFileNode: View {
    let node: ReviewFileTree
    let model: ReviewModel
    var depth = 0
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if let children = node.children {
            let isExpanded = !model.collapsedSessionFolders.contains(node.path)
            Button {
                if isExpanded { model.collapsedSessionFolders.insert(node.path) } else { model.collapsedSessionFolders.remove(node.path) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6.5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .reviewRow(leading: Double(depth) * ReviewInset.tree)
            if isExpanded {
                ForEach(children) { Self(node: $0, model: model, depth: depth + 1) }
            }
        } else {
            label
                .padding(.vertical, 6.5)
                .reviewRow(leading: Double(depth + 1) * ReviewInset.tree)
                .modifier(ReviewRowChrome(document: sessionFileDocument(node.path), model: model))
                .id(sessionFileDocument(node.path))
        }
    }

    private var label: some View {
        Label {
            Text(node.name)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.regular)
        } icon: {
            Image(systemName: node.children == nil ? "doc" : "folder")
                .foregroundStyle(theme.secondary)
        }
        .font(.subheadline)
        .help(node.path.hasPrefix("~") ? node.path : "/" + node.path)
    }
}

private struct ReviewChangeRow: View {
    let file: ReviewFile
    let model: ReviewModel
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    private var showsOpenFile: Bool {
        guard file.status != .deleted else { return false }

        #if DEBUG
        if UserDefaults.standard.string(forKey: "snapshotReviewHoverRow") == file.path { return true }
        #endif
        return isHovering
    }

    var body: some View {
        row
            .padding(.vertical, 7)
            .onHover { isHovering = $0 }
            .contextMenu {
                if file.status != .deleted {
                    Button("Open File", systemImage: "doc") { model.open(ReviewDocument(path: file.path, compare: nil)) }
                }
            }
            .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    private var row: some View {
        let status = switch file.status {
        case .added, .untracked: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
        return HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.caption2.weight(.medium).monospaced())
                .foregroundStyle(file.status.color(in: theme))
                .frame(width: 12)
                .accessibilityLabel(status)
            Text((file.path as NSString).lastPathComponent)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.regular)
            Spacer(minLength: 4)
            ReviewFileStats(file: file)
                .opacity(showsOpenFile ? 0 : 1)
                .overlay(alignment: .trailing) { openFileSlot }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var openFileSlot: some View {
        if showsOpenFile {
            Button("Open File", systemImage: "doc") { model.open(ReviewDocument(path: file.path, compare: nil)) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(theme.secondary)
                .help("Open File")
                .fixedSize()
                .padding(.trailing, 2)
        }
    }
}

private struct ReviewFileNode: View {
    let node: ReviewFileTree
    let compare: ReviewCompare?
    let changes: ReviewChanges
    let model: ReviewModel
    var root: String?
    var depth = 0
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if let children = node.children {
            Button { isExpanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, compare == nil ? 6.5 : 7.5)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .reviewRow(leading: Double(depth) * ReviewInset.tree)
            .modifier(ReviewRowChrome(document: nil, model: model))
            if isExpanded.wrappedValue {
                ForEach(children) { Self(node: $0, compare: compare, changes: changes, model: model, root: root, depth: depth + 1) }
            }
        } else if let compare, let file = (compare == .committed ? changes.committed : changes.uncommitted).first(where: { $0.path == node.path }) {
            let document = ReviewDocument(path: node.path, compare: compare, root: root)
            ReviewChangeRow(file: file, model: model)
                .reviewRow(leading: Double(depth + 1) * ReviewInset.tree)
                .modifier(ReviewRowChrome(document: document, model: model, opensWorkingFile: file.status != .deleted))
                .id(document)
        } else {
            let document = ReviewDocument(path: node.path, compare: nil)
            label
                .padding(.vertical, 6.5)
                .reviewRow(leading: Double(depth + 1) * ReviewInset.tree)
                .modifier(ReviewRowChrome(document: document, model: model, followsFilePath: true))
                .id("file:" + node.path)
        }
    }

    private var isExpanded: Binding<Bool> {
        guard let compare else { return Binding { model.expandedFolders.contains(node.path) } set: { $0 ? model.expandedFolders.formUnion([node.path]) : model.expandedFolders.subtract([node.path]) } }

        let folder = ReviewDocument(path: node.path, compare: compare)
        return Binding { !model.collapsedChangeFolders.contains(folder) } set: { $0 ? model.collapsedChangeFolders.subtract([folder]) : model.collapsedChangeFolders.formUnion([folder]) }
    }

    private var label: some View {
        let status = (changes.uncommitted.first { $0.path == node.path } ?? changes.committed.first { $0.path == node.path })?.status
        return Label {
            Text(node.name)
                .monospaced()
                .foregroundStyle(status?.color(in: theme) ?? theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.regular)
        } icon: {
            Image(systemName: node.children == nil ? "doc" : "folder")
                .foregroundStyle(theme.secondary)
        }
        .font(.subheadline)
        .help(node.path)
    }
}

struct PullRequestStatePill: View {
    let pullRequest: PullRequest
    var opensOnGitHub = true
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        if opensOnGitHub {
            Button { openURL(pullRequest.url) } label: { pill }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .pointerStyle(.link)
                .help("Open pull request #\(String(pullRequest.number)) on GitHub")
        } else {
            pill
        }
    }

    private var pill: some View {
        let color = pullRequest.state.color(in: theme)
        return Label { Text(pullRequest.state.rawValue) } icon: { OcticonImage(Octicon(pullRequest.state)) }
            .labelStyle(CompactLabel())
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(isHovering ? 0.28 : 0.16), in: .rect(cornerRadius: 4))
    }
}

struct GlassCapsule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0, content: { content })
            .labelStyle(.iconOnly)
            .buttonStyle(GlassCapsuleButtonStyle())
            .font(.caption)
            .padding(.horizontal, 3)
            .frame(height: 24)
            .glassEffect(.regular, in: .capsule)
    }
}

private struct GlassCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 22, height: 24)
            .contentShape(.rect)
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
    }
}

struct ReviewDiffColumn: View {
    let store: Store
    @AppStorage(ReviewStyle.colorSchemeKey) private var colorScheme = ReviewColorScheme.terminal
    @AppStorage(ReviewStyle.syntaxColorsKey) private var syntaxColors = SyntaxColorSource.terminal
    @AppStorage(ReviewStyle.fontFamilyKey) private var fontFamily = ""
    @AppStorage(ReviewStyle.fontSizeKey) private var fontSize = 0.0
    @AppStorage(ReviewStyle.lineHeightKey) private var lineHeight = 1.3
    @AppStorage(GeneralSettings.languageServersKey) private var areLanguageServersEnabled = false
    @AppStorage(ReviewDiffLayout.key) private var diffLayout = ReviewDiffLayout.auto
    @AppStorage(ReviewStyle.wrapsLinesKey) private var wrapsLines = false
    @State private var isNarrow = false
    @State private var measuredNarrow = false

    private var isUnified: Bool { diffLayout == .inline || diffLayout == .auto && isNarrow }

    var body: some View {
        let style = ReviewStyle(scheme: colorScheme, fontFamily: fontFamily, fontSize: fontSize, lineHeightMultiple: lineHeight, ghostty: store.theme).withSyntaxColors(syntaxColors)
        Group {
            if let model = store.reviewModel, model.isPreviewSelected {
                VStack(spacing: 0) {
                    strip(model, tab: nil, style: style)
                    Divider()
                    ReviewPreviewView(model: model, rootPID: store.selectedSessionID.flatMap { store.liveBySession[$0]?.pid })
                }
            } else if let model = store.reviewModel, let tab = model.selectedTab, tab.document.pullRequestTab == .details,
                      let link = tab.document.pullRequestLink, let pullRequest = model.pullRequestsForDetails[link] {
                VStack(spacing: 0) {
                    strip(model, tab: tab, style: style)
                    Divider()
                    ReviewPullRequestDetails(pullRequest: pullRequest)
                        .id(link)
                }
            } else if let model = store.reviewModel, let tab = model.selectedTab, tab.document.pullRequestTab == .diff, tab.document.path.isEmpty {
                VStack(spacing: 0) {
                    strip(model, tab: tab, style: style)
                    Divider()
                    ContentUnavailableView("No changed files", systemImage: "doc")
                }
            } else if let model = store.reviewModel, let tab = model.selectedTab {
                let document = tab.document
                let path = document.path
                let sessionID = store.selectedSessionID
                let root = sessionID.flatMap { store.activeReviewRoots[$0] }
                let target = sessionID.flatMap { store.shownReviewPullRequest(for: model, sessionID: $0, root: root) }
                let number = target?.pullRequest?.number
                let detail = number.flatMap { model.pullRequestDetails[$0] }
                let isOtherClone = document.root.map { $0 != model.changes?.root } == true
                let revealLine = model.revealLine.flatMap { $0.document == document ? (line: $0.line, side: $0.side) : nil }
                let isReadOnly = model.isReadOnly(document)
                VStack(spacing: 0) {
                    strip(model, tab: tab, style: style)
                    Divider()
                    ReviewPathBar(model: model, document: document, style: style)
                    Divider()
                    if !isReadOnly, model.hasDiskConflict(path) { ReviewDiskChangeBar(model: model, path: path) }
                    if let contents = model.contents[document], isReadOnly || model.editors[path] != nil {
                        ReviewDiffPane(
                            path: path,
                            compare: document.compare,
                            contents: contents,
                            editor: isReadOnly ? nil : model.editors[path],
                            draft: isReadOnly ? .constant(nil) : Binding(get: { model.drafts[path] }, set: { draft in
                                model.drafts[path] = draft
                                model.keep(tab.id)
                            }),
                            comments: Bindable(model).comments,
                            threads: detail?.threads.filter { $0.path == path && $0.line != nil && document.compare?.isHistorical != true } ?? [],
                            replyDrafts: Bindable(model).replyDrafts,
                            isWritingPullRequest: model.isWritingPullRequest,
                            style: style,
                            blameRevision: model.blameRevision,
                            loadBlame: { await model.loadBlame(for: document) },
                            language: areLanguageServersEnabled ? model.language : nil,
                            reveal: model.reveal.flatMap { $0.document == document ? $0.range : nil },
                            revealLine: revealLine,
                            isUnified: isUnified || !model.selectedDocumentHasBothSides,
                            takesFocus: model.focusesEditor,
                            changeStep: model.changeStep,
                            onRevealed: { model.reveal = nil },
                            onLineRevealed: {
                                if let pending = model.revealLine, pending.document == document, pending.line == revealLine?.line, pending.side == revealLine?.side {
                                    model.revealLine = nil
                                }
                            },
                            onChangeStepped: { model.changeStep = nil },
                            editsComment: model.editingComment,
                            onEditing: { model.editingComment = nil },
                            onDefinition: model.goToDefinition,
                            onReply: { threadID, body in
                                guard let target, let number else { return false }

                                return await model.sendReply(repository: target.repository, number: number, threadID: threadID, body: body)
                            },
                            onSendThread: { thread in
                                guard let sessionID else { return }

                                let repository = root.map { (URL(filePath: $0).lastPathComponent, model.changes?.root ?? $0) }
                                store.sendReviewPrompt(ReviewThread.prompt(for: thread, repository: repository), sessionID: sessionID, noticeIn: model)
                            },
                            onSendComment: document.compare?.isHistorical != true && detail?.id != nil ? { comment in
                                guard let target, let number else { return }

                                Task { await model.sendToPullRequest(comment, repository: target.repository, number: number) }
                            } : nil,
                            workingText: { model.workingText(path) },
                            markdown: store.rendersMarkdown && document.isMarkdown && !isOtherClone ? ReviewMarkdownContext(root: URL(filePath: model.changes?.root ?? model.folder), open: { model.open(model.workingDocument($0)) }) : nil
                        )
                        .id(document)
                        .id(isReadOnly)
                        .task(id: model.focusesEditor) { model.focusesEditor = false }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    if let model = store.reviewModel { strip(model, tab: nil, style: style) } else { Spacer().frame(height: 32) }
                    Divider()
                    Text("No File Open")
                        .font(.title2)
                        .foregroundStyle(Color(nsColor: style.secondary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color(nsColor: style.foreground))
        .background(Color(nsColor: style.background))
        .overlay { CardBorder() }
        .environment(\.colorScheme, style.isDark ? .dark : .light)
        .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { measuredNarrow = $0 }
        .task(id: [measuredNarrow, store.showsReviewPanel && !store.isHarborShown]) {
            guard await (try? Task.sleep(for: .milliseconds(50))) != nil, store.showsReviewPanel, !store.isHarborShown else { return }

            isNarrow = measuredNarrow
        }
        .onChange(of: isUnified, initial: true) { store.isReviewDiffUnified = isUnified }
        .environment(store)
        .environment(\.ghosttyTheme, store.theme)
    }

    private func strip(_ model: ReviewModel, tab: ReviewTab?, style: ReviewStyle) -> some View {
        GlassEffectContainer {
            HStack {
                if let tab {
                    GlassCapsule {
                        Button(AppAction.goBack.title, systemImage: AppAction.goBack.symbol) { model.go(by: -1) }
                            .disabled(tab.index == 0)
                            .help("\(AppAction.goBack.title) (⌃-)")
                        Button(AppAction.goForward.title, systemImage: AppAction.goForward.symbol) { model.go(by: 1) }
                            .disabled(tab.index == tab.history.count - 1)
                            .help("\(AppAction.goForward.title) (⌃⇧-)")
                    }
                    .padding(.leading, 10)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(model.tabs) { tabButton($0, in: model, style: style).id($0.id) }
                        }
                        .padding(.leading, 6)
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selectedTabID, initial: true) { _, id in
                        guard let id else { return }

                        withAnimation { proxy.scrollTo(id) }
                    }
                }
                previewTabButton(in: model, style: style)
                    .padding(.trailing, 2)
                    .padding(.vertical, 4)
                if tab?.document.compare != nil {
                    GlassCapsule {
                        Button("Previous Change", systemImage: "chevron.up") { model.changeStep = -1 }
                            .help("Previous Change (⌃⌥↑)")
                        Button("Next Change", systemImage: "chevron.down") { model.changeStep = 1 }
                            .help("Next Change (⌃⌥↓)")
                    }
                    .padding(.leading, 6)
                }
                HStack(spacing: 6) {
                    if let tab, !tab.document.path.isEmpty {
                        GlassCapsule {
                            if tab.document.isMarkdown {
                                let action = store.rendersMarkdown ? AppAction.showMarkdownSource : .showRenderedMarkdown
                                Button(action.title, systemImage: action.symbol) { action.perform(on: store) }
                                    .foregroundStyle(store.rendersMarkdown ? Color.accentColor : Color(nsColor: style.secondary))
                                    .help("\(action.title) (⇧⌘M)")
                            }
                            if !tab.document.isMarkdown || !store.rendersMarkdown {
                                Button("Wrap Lines", systemImage: "arrow.turn.down.left") { wrapsLines.toggle() }
                                    .foregroundStyle(wrapsLines ? Color.accentColor : Color(nsColor: style.secondary))
                                    .help("Wrap Lines")
                            }
                            if model.selectedDocumentHasBothSides {
                                Button(isUnified ? "Show Side by Side" : "Show Inline", systemImage: isUnified ? "rectangle.split.2x1" : "rectangle") {
                                    diffLayout = isUnified ? .sideBySide : .inline
                                }
                                .help(isUnified ? "Show Side by Side" : "Show Inline")
                            }
                            if AppAction.save.isAvailable(in: store) {
                                Button(AppAction.save.title, systemImage: AppAction.save.symbol) { AppAction.save.perform(on: store) }
                                    .help("\(AppAction.save.title) (⌘S)")
                            }
                        }
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 10)
            }
        }
        .foregroundStyle(Color(nsColor: style.secondary))
        .frame(height: 32)
    }

    private func previewTabButton(in model: ReviewModel, style: ReviewStyle) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.caption)
                .accessibilityHidden(true)
            Text("Preview")
                .lineLimit(1)
            if model.isPreviewOpen {
                Button("Close Preview", systemImage: "xmark") { model.closePreview() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        }
        .font(.callout)
        .foregroundStyle(Color(nsColor: model.isPreviewSelected ? style.foreground : style.secondary))
        .opacity(model.isPreviewOpen ? 1 : 0.6)
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: style.foreground).opacity(model.isPreviewSelected ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { model.showPreview() }
        .help(model.isPreviewOpen ? "Preview" : "Open Preview (View ▸ Open Preview)")
    }

    private func tabButton(_ tab: ReviewTab, in model: ReviewModel, style: ReviewStyle) -> some View {
        let document = tab.document
        let isSelected = tab.id == model.selectedTabID && !model.isPreviewSelected
        let name = (document.path as NSString).lastPathComponent
        let folders = document.path.split(separator: "/").dropLast()
        let namesakes = Set(model.tabs.map(\.document.path)).subtracting([document.path]).filter { ($0 as NSString).lastPathComponent == name }.map { $0.split(separator: "/").dropLast() }
        let parents = namesakes.isEmpty ? [] : (1..<folders.count + 1).lazy.map { folders.suffix($0) }.first { suffix in namesakes.allSatisfy { $0.suffix(suffix.count) != suffix } } ?? folders
        let compare = switch document.compare {
        case .committed: " (Committed)"
        case .uncommitted: " (Uncommitted)"
        case let .commit(sha): " (\(sha.prefix(7)))"
        case .range: document.pullRequestNumber.map { " (PR #\($0))" } ?? ""
        case nil: ""
        }
        let title = if let number = document.pullRequestNumber {
            switch document.pullRequestTab {
            case .details: "PR #\(number) details"
            case .diff: "PR #\(number)"
            case nil: "PR #\(number) · \(name)"
            }
        } else if document.compare?.isHistorical == true {
            name + compare
        } else {
            name
        }
        let previewHint = if !tab.isPreview { "" } else if model.isReadOnly(document) { ". Double-click to keep this preview tab." } else { ". Double-click or edit to keep this preview tab." }
        return HStack(spacing: 6) {
            Image(systemName: document.compare == nil ? "doc" : "plus.forwardslash.minus")
                .font(.caption)
                .accessibilityHidden(true)
            Text(title)
                .monospaced()
                .italic(tab.isPreview)
                .lineLimit(1)
            if !parents.isEmpty {
                Text(parents.joined(separator: "/"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Close Tab", systemImage: "xmark") { store.closeDiff(tab: tab.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .font(.callout)
        .foregroundStyle(Color(nsColor: isSelected ? style.foreground : style.secondary))
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: style.foreground).opacity(isSelected ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture { model.selectedTabID = tab.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.keep(tab.id) })
        .help("\(document.path.isEmpty ? title : document.path + compare)\(previewHint)")
        .contextMenu {
            if !document.path.isEmpty {
                let absolute = (document.root ?? model.changes?.root).map { ($0 as NSString).appendingPathComponent(document.path) }
                if let absolute {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(absolute, forType: .string)
                    }
                }
                Button("Copy Relative Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.path, forType: .string)
                }
                Button("Reveal in Files") {
                    model.selectedTabID = tab.id
                    model.filesReveal = document.path
                }
                .disabled(document.pullRequestLink != nil || model !== store.primaryReviewModel || !FileManager.default.fileExists(atPath: absolute ?? ""))
                Divider()
            }
            Button("Close") { store.closeDiff(tab: tab.id) }
            Button("Close Others") {
                model.selectedTabID = tab.id
                for other in model.tabs where other.id != tab.id { model.close(other.id) }
            }
            .disabled(model.tabs.count == 1)
        }
    }
}
