import BerthCore
import GhosttyTerminal
import SwiftUI

struct ReviewDocument: Hashable {
    let path: String
    let compare: ReviewCompare?
    var root: String?
}

struct ReviewTab: Identifiable {
    let id: UUID
    var history: [(document: ReviewDocument, range: LanguageServerRange?)]
    var index: Int
    var isPreview: Bool

    var document: ReviewDocument { history[index].document }
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
    private(set) var changes: ReviewChanges?
    private(set) var status: ReviewBranchStatus?
    private(set) var tree: [ReviewFileTree] = []
    private(set) var pullRequestDetails: [Int: PullRequestDetail] = [:]
    private(set) var error: (any Error)?
    private(set) var isLoading = false
    private(set) var contents: [ReviewDocument: ReviewContents] = [:]
    private(set) var language: ReviewLanguage?
    private(set) var tabs: [ReviewTab] = []
    var selectedTabID: UUID?
    var reveal: (document: ReviewDocument, range: LanguageServerRange)?
    var drafts: [String: String] = [:]
    var comments: [ReviewComment] = []
    var editingComment: String?
    var notice: String?
    var movedFolder: String?
    var focusesEditor = false
    @ObservationIgnored var pullRequestBase: (branch: String, base: String)?
    @ObservationIgnored var onOpen: () -> Void = {}
    var filesReveal: String?
    var expandedFolders: Set<String> = []
    var collapsedChangeFolders: Set<ReviewDocument> = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var queuedLoad: Task<Void, Never>?
    @ObservationIgnored private(set) var loadCount = 0
    @ObservationIgnored private var loadedTexts: [String: String] = [:]
    @ObservationIgnored private(set) var editors: [String: ReviewTextView] = [:]
    @ObservationIgnored private var savedFromCommitted: Set<String> = []

    var hasUnsavedEdits: Bool { !drafts.isEmpty }
    var selectedTab: ReviewTab? { tabs.first { $0.id == selectedTabID } }
    var selectedDocument: ReviewDocument? { selectedTab?.document }
    var selectedDocumentHasBothSides: Bool {
        guard let document = selectedDocument, let compare = document.compare else { return false }

        let status = (compare == .committed ? changes?.committed : changes?.uncommitted)?.first { $0.path == document.path }?.status
        return status != nil && status != .added && status != .deleted
    }

    static let baseBranchesKey = "reviewBaseBranches"

    init(folder: String) {
        self.folder = folder
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
                if let compare = document.compare, (compare == .committed ? changes.committed : changes.uncommitted).contains(where: { $0.path == document.path }) { return document }
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
    }

    func pickBase(_ ref: String) {
        guard let changes else { return }

        var picks = UserDefaults.standard.dictionary(forKey: Self.baseBranchesKey) as? [String: [String: String]] ?? [:]
        picks[changes.root, default: [:]][changes.branch] = ref
        UserDefaults.standard.set(picks, forKey: Self.baseBranchesKey)
        Task { await load() }
    }

    func open(_ document: ReviewDocument) {
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

        tabs.remove(at: index)
        if selectedTabID == id { selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func workingDocument(_ path: String) -> ReviewDocument {
        ReviewDocument(path: path, compare: changes?.uncommitted.contains { $0.path == path } == true ? .uncommitted : nil)
    }

    func loadPullRequestDetail(repository: String, number: Int) async {
        let detail = Snapshot.output != nil ? Snapshot.fixturePullRequestDetail : await Task.detached { PullRequestStatus.detail(repository: repository, number: number) }.value
        if let detail { pullRequestDetails[number] = detail }
    }

    func loadSelectedContents() async {
        guard let document = selectedDocument, contents[document] == nil else { return }

        await loadContents(of: document)
    }

    private func loadContents(of document: ReviewDocument) async {
        guard let changes else { return }

        do {
            let listed = document.compare.flatMap { compare in (compare == .committed ? changes.committed : changes.uncommitted).first { $0.path == document.path } }
            let text = listed == nil ? try ReviewGit.workingTreeText(document.path, in: changes.root) : nil
            let loaded = if let listed, let compare = document.compare { try await ReviewGit.contents(of: listed, compare: compare, in: changes) } else { ReviewContents(original: text, modified: text) }
            contents[document] = loaded
            guard document.compare != .committed || !changes.uncommitted.contains(where: { $0.path == document.path }) else { return }

            if drafts[document.path] == nil { loadedTexts[document.path] = if case let .text(text)? = loaded.modified { text } else { nil } }
            editors[document.path] = editors[document.path] ?? ReviewTextView(usingTextLayoutManager: true)
            setWorkingTreeText(loaded.modified, of: document.path)
        } catch {
            notice = "Couldn’t read \(document.path): \(Self.describe(error))"
        }
    }

    func goToDefinition(_ location: LanguageServerLocation, from origin: LanguageServerRange) {
        let target = location.url.resolvingSymlinksInPath().path
        guard let root = changes.map({ URL(filePath: $0.root).resolvingSymlinksInPath().path + "/" }), target.hasPrefix(root), let current = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }

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
        guard let changes, changes.uncommitted.first(where: { $0.path == path })?.status != .deleted else {
            notice = "\(path) is read only here"
            return
        }
        guard let expected = loadedTexts[path], (try? ReviewGit.workingTreeText(path, in: changes.root)) == .text(expected) else {
            notice = "\(path) changed on disk; reload before saving"
            return
        }

        do {
            try ReviewGit.save(text, to: path, in: changes.root)
        } catch {
            notice = "Couldn’t save \(path): \(Self.describe(error))"
            return
        }
        loadedTexts[path] = text
        drafts[path] = nil
        if selectedDocument == ReviewDocument(path: path, compare: .committed) { savedFromCommitted.insert(path) }
        setWorkingTreeText(.text(text), of: path)
    }

    private func setWorkingTreeText(_ text: ReviewText?, of path: String) {
        for document in contents.keys where document.path == path && (document.compare != .committed || changes?.uncommitted.contains { $0.path == path } == false) {
            contents[document] = contents[document].map { ReviewContents(original: document.compare == nil ? text : $0.original, modified: text) }
        }
    }

    static func describe(_ error: any Error) -> String {
        guard case let ReviewGitError.git(_, message) = error else { return String(describing: error) }

        return message
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

private struct ReviewFileList: View {
    let sessionID: String
    @Bindable var model: ReviewModel
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage("collapsedReviewSections") private var collapsedSections = "files"
    @AppStorage("reviewFilesPaneHeight") private var filesPaneHeight = 0.0
    @AppStorage("reviewChangesAsTree") private var changesAsTree = false
    @State private var changesContentHeight = 0.0
    @State private var filesHeaderHeight = 0.0
    @FocusState private var focusedList: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await model.load() }
            .task(id: [model.changes?.branch, pullRequest?.pullRequest?.baseRefName]) {
                let base = model.changes.flatMap { changes in pullRequest?.pullRequest?.baseRefName.map { (branch: changes.branch, base: $0) } }
                guard base?.branch != model.pullRequestBase?.branch || base?.base != model.pullRequestBase?.base else { return }

                model.pullRequestBase = base
                await model.load()
            }
            .onChange(of: owners.contains { $0.model.hasUnsavedEdits || !$0.model.comments.isEmpty }) { store.prepareReviewModel() }
            .task(id: selection) { await (store.reviewModel ?? model).loadSelectedContents() }
            .task(id: extraStates) { for extra in extras { await prepare(extra.repository, extra.model) } }
            .task(id: pullRequest?.pullRequest?.number) { await loadPullRequestDetail() }
            .alert("Review", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in
            } message: { notice in
                Text(notice)
            }
    }

    @ViewBuilder private var content: some View {
        if let changes = model.changes {
            VStack(spacing: 0) {
                header(changes)
                if let movedFolder = model.movedFolder {
                    Label("This session moved to \((movedFolder as NSString).abbreviatingWithTildeInPath). Save or undo your edits and send or delete your comments to follow it.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(theme.needsYou)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
                if !isStacked, let status = model.status {
                    branchCard(changes, status)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
                ReviewFilesSplit(
                    changes: list(name: "changes", order: order(changes)) { if isStacked { stackedSections(changes) } else { changeSections(changes) } }
                        .id(changesAsTree ? ([changes] + extras.compactMap(\.model.changes)).flatMap { [$0.uncommitted, $0.committed].map { ReviewFileTree.compactNodes($0.map(\.path)).flatMap(\.folderPaths) } } : nil)
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: { changesContentHeight = $1 }
                        .onChange(of: (store.reviewModel ?? model).selectedDocument, initial: true) { _, document in
                            guard let document, let compare = document.compare, let active = store.reviewModel else { return }

                            active.collapsedChangeFolders = active.collapsedChangeFolders.filter { $0.compare != compare || !document.path.hasPrefix($0.path + "/") }
                        }
                        .environment(\.ghosttyTheme, theme),
                    files: VStack(spacing: 0) {
                        list { filesHeader }
                            .scrollDisabled(true)
                            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: { filesHeaderHeight = $1 }
                            // Expanded, the List's own 10 pt of vertical padding would otherwise sit between the header and the tree.
                            .frame(height: expansion(of: "files").wrappedValue ? max(filesHeaderHeight - 10, 0) : filesHeaderHeight)
                        ScrollViewReader { proxy in
                            list(name: "files", order: expansion(of: "files").wrappedValue ? model.tree.flatMap { leaves(of: $0, compare: nil, in: model, root: nil) } : []) { ForEach(model.tree) { ReviewFileNode(node: $0, compare: nil, changes: changes, model: model) } }
                                .onChange(of: [model.selectedDocument?.path, model.filesReveal], initial: true) {
                                    guard let path = model.filesReveal ?? model.selectedDocument?.path else { return }

                                    if model.filesReveal != nil, !expansion(of: "files").wrappedValue { expansion(of: "files").wrappedValue = true }
                                    model.filesReveal = nil
                                    model.expandedFolders.formUnion(path.split(separator: "/").dropLast().reduce(into: [String]()) { $0.append(($0.last.map { $0 + "/" } ?? "") + $1) })
                                    Task { proxy.scrollTo(path) }
                                }
                        }
                    }
                    .environment(\.ghosttyTheme, theme),
                    layout: !expansion(of: "files").wrappedValue ? .filesCollapsed(filesHeaderHeight) : areChangesCollapsed(changes) ? .changesCollapsed(changesContentHeight) : .split,
                    filesHeight: $filesPaneHeight,
                    divider: NSColor(theme.foreground.opacity(0.1))
                )

                if owners.contains(where: { !$0.model.comments.isEmpty }) {
                    Hairline(axis: .horizontal)
                    comments
                }
            }
        } else if let error = model.error, case ReviewGitError.notARepository = error, !extras.isEmpty {
            VStack(spacing: 0) {
                list { stackedSections(nil) }
                    .environment(\.ghosttyTheme, theme)
                if owners.contains(where: { !$0.model.comments.isEmpty }) {
                    Hairline(axis: .horizontal)
                    comments
                }
            }
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

    private func list(name: String = "", order: [ReviewDocument] = [], @ViewBuilder _ sections: () -> some View) -> some View {
        let content = sections()
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
                .listStyle(.sidebar)
                .environment(\.sidebarRowSize, .small)
                .scrollContentBackground(.hidden)
        }
    }

    private func step(_ offset: Int, in order: [ReviewDocument], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }

        let current = selection.flatMap(order.firstIndex(of:))
        let next = order[min(max((current ?? (offset > 0 ? -1 : order.count)) + offset, 0), order.count - 1)]
        open(next)
        proxy.scrollTo(next.path)
        return .handled
    }

    private func order(_ changes: ReviewChanges?) -> [ReviewDocument] {
        guard isStacked else {
            guard let changes else { return [] }

            return (expansion(of: "uncommitted").wrappedValue ? documents(changes.uncommitted, compare: .uncommitted, in: model, root: nil) : [])
                + (expansion(of: "committed").wrappedValue ? documents(changes.committed, compare: .committed, in: model, root: nil) : [])
        }

        let own = changes.flatMap { changes in
            repositoryExpansion(store.repositoryRoot(ofSession: sessionID) ?? model.folder).wrappedValue ? documents(changes.uncommitted, compare: .uncommitted, in: model, root: nil) + documents(changes.committed, compare: .committed, in: model, root: nil) : nil
        } ?? []
        let others = extras.flatMap { extra -> [ReviewDocument] in
            guard repositoryExpansion(extra.repository.root).wrappedValue, let changes = extra.model.changes else { return [] }

            return documents(changes.uncommitted, compare: .uncommitted, in: extra.model, root: extra.repository.root) + documents(changes.committed, compare: .committed, in: extra.model, root: extra.repository.root)
        }
        return own + others
    }

    private func documents(_ files: [ReviewFile], compare: ReviewCompare, in model: ReviewModel, root: String?) -> [ReviewDocument] {
        guard changesAsTree else { return files.map { ReviewDocument(path: $0.path, compare: compare, root: root) } }

        return ReviewFileTree.compactNodes(files.map(\.path)).flatMap { leaves(of: $0, compare: compare, in: model, root: root) }
    }

    private func leaves(of node: ReviewFileTree, compare: ReviewCompare?, in model: ReviewModel, root: String?) -> [ReviewDocument] {
        guard let children = node.children else { return [ReviewDocument(path: node.path, compare: compare, root: root)] }

        let isExpanded = compare.map { !model.collapsedChangeFolders.contains(ReviewDocument(path: node.path, compare: $0)) } ?? model.expandedFolders.contains(node.path)
        return isExpanded ? children.flatMap { leaves(of: $0, compare: compare, in: model, root: root) } : []
    }

    @discardableResult
    private func open(_ document: ReviewDocument) -> ReviewModel {
        let target = document.root.flatMap { store.reviewModels[Store.reviewKey(sessionID, root: $0)] } ?? model
        let plain = ReviewDocument(path: document.path, compare: document.compare)
        target.open(plain.compare == nil ? target.workingDocument(plain.path) : plain)
        return target
    }

    private var selection: ReviewDocument? {
        let active = store.reviewModel ?? model
        return active.selectedDocument.map { ReviewDocument(path: $0.path, compare: $0.compare, root: active === model ? nil : store.activeReviewRoots[sessionID]) }
    }

    @ViewBuilder
    private func changeSections(_ changes: ReviewChanges) -> some View {
        if changes.uncommitted.isEmpty, changes.committed.isEmpty {
            Text(changes.isDefaultBranch || changes.base == nil ? "No uncommitted changes on \(changes.branch)" : "No changes, \(changes.branch) matches \(changes.base ?? "")")
                .foregroundStyle(theme.secondary)
        }
        if !changes.uncommitted.isEmpty {
            Section(isExpanded: expansion(of: "uncommitted")) {
                changeRows(changes.uncommitted, compare: .uncommitted, changes: changes, in: model, root: nil)
            } header: {
                GroupHeader(title: "Uncommitted", help: "HEAD to the working tree", count: changes.uncommitted.count) { EmptyView() } accessory: { _ in
                    Text("+\(changes.uncommitted.compactMap(\.additions).reduce(0, +)) −\(changes.uncommitted.compactMap(\.deletions).reduce(0, +))")
                        .monospacedDigit()
                        .foregroundStyle(theme.secondary)
                        .padding(.trailing, 6)
                }
            }
        }
        if !changes.committed.isEmpty {
            Section(isExpanded: expansion(of: "committed")) {
                changeRows(changes.committed, compare: .committed, changes: changes, in: model, root: nil)
            } header: {
                GroupHeader(title: "Committed", help: "\(changes.base ?? "The base") to HEAD", count: changes.committed.count) { EmptyView() } accessory: { _ in
                    Text("+\(changes.committed.compactMap(\.additions).reduce(0, +)) −\(changes.committed.compactMap(\.deletions).reduce(0, +))")
                        .monospacedDigit()
                        .foregroundStyle(theme.secondary)
                        .padding(.trailing, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func changeRows(_ files: [ReviewFile], compare: ReviewCompare, changes: ReviewChanges, in model: ReviewModel, root: String?) -> some View {
        if changesAsTree {
            ForEach(ReviewFileTree.compactNodes(files.map(\.path))) { ReviewFileNode(node: $0, compare: compare, changes: changes, model: model, root: root) }
        } else {
            ForEach(files, id: \.path) { file in
                let document = ReviewDocument(path: file.path, compare: compare, root: root)
                ReviewChangeRow(file: file, model: model)
                    .modifier(ReviewRowChrome(document: document, model: model))
            }
        }
    }

    private func branchCard(_ changes: ReviewChanges, _ status: ReviewBranchStatus) -> some View {
        ReviewBranchCard(changes: changes, status: status, pullRequest: pullRequest.map(\.pullRequest), detail: pullRequest?.pullRequest.flatMap { model.pullRequestDetails[$0.number] }, isClaudeLive: store.liveBySession[sessionID] != nil, createPullRequest: createPullRequest)
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

    private var owners: [(model: ReviewModel, repository: ReviewRepository?)] {
        [(model, nil)] + allExtras.map { ($0.model, $0.repository) }
    }

    private var isStacked: Bool { store.task(containing: sessionID) != nil || !extras.isEmpty }

    private var extraStates: [String] {
        extras.map { "\($0.repository.root)|\($0.model.changes?.branch ?? "")|\(store.pullRequests(inRoot: $0.repository.root, of: sessionID, branch: $0.model.changes?.branch).map { "\($0.number)\($0.baseRefName ?? "")" })" }
    }

    private func extraPullRequest(_ root: String, _ branch: String) -> (repository: String, pullRequest: PullRequest?)? {
        guard let key = store.pullRequestBranch(inRoot: root, branch: branch), let found = store.pullRequests[key] else { return nil }

        return (key.repository, found)
    }

    private func prepare(_ repository: ReviewRepository, _ model: ReviewModel) async {
        if model.changes == nil { await model.load() }
        guard let branch = model.changes?.branch else { return }

        let key = store.pullRequestBranch(inRoot: repository.root, branch: branch)
        let found = key.flatMap { store.pullRequests[$0] ?? nil }
        if let key, let found, model.pullRequestDetails[found.number] == nil { await model.loadPullRequestDetail(repository: key.repository, number: found.number) }
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

    private func areChangesCollapsed(_ changes: ReviewChanges) -> Bool {
        guard isStacked else { return (changes.uncommitted.isEmpty || !expansion(of: "uncommitted").wrappedValue) && (changes.committed.isEmpty || !expansion(of: "committed").wrappedValue) }

        return !repositoryExpansion(store.repositoryRoot(ofSession: sessionID) ?? model.folder).wrappedValue && extras.allSatisfy { !repositoryExpansion($0.repository.root).wrappedValue }
    }

    @ViewBuilder
    private func stackedSections(_ changes: ReviewChanges?) -> some View {
        let ownRoot = store.repositoryRoot(ofSession: sessionID) ?? model.folder
        let inset = changesAsTree ? 9.0 : 0.0
        if let task = store.task(containing: sessionID) {
            let members = task.sessionIDs.compactMap { store.sessionsByID[$0] }.sorted { $0.lastPrompt > $1.lastPrompt }
            ReviewTaskCard(
                title: store.title(of: task),
                issue: task.issue,
                members: members,
                currentID: sessionID,
                pullRequestCount: store.pullRequestCount(of: members),
                repositoryCount: Set(members.compactMap { store.repositoryRoot(ofSession: $0.id) } + [ownRoot] + extras.map(\.repository.root)).count,
                isExpanded: repositoryExpansion(task.id),
                activate: { store.activate(.session($0)) }
            )
            .listRowInsets(EdgeInsets(top: 0, leading: -7.5 - inset, bottom: 4, trailing: -8))
            .listRowSeparator(.hidden)
        }
        if let changes {
            Section(isExpanded: repositoryExpansion(ownRoot)) {
                branchCard(changes, model.status ?? .unknown)
                    .listRowInsets(EdgeInsets(top: 0, leading: -7.5 - inset, bottom: 6, trailing: -8))
                stackedRows(changes, in: model, root: nil, indent: inset)
            } header: {
                GroupHeader(title: URL(filePath: ownRoot).lastPathComponent, help: ownRoot, count: nil) { EmptyView() } accessory: { _ in
                    ReviewRepositoryAccessory(branch: nil, base: nil, pullRequests: store.pullRequests(inRoot: nil, of: sessionID, branch: changes.branch).filter { !repositoryExpansion(ownRoot).wrappedValue || $0.number != pullRequest?.pullRequest?.number })
                }
            }
        }
        ForEach(extras, id: \.repository.root) { extra in
            Section(isExpanded: repositoryExpansion(extra.repository.root)) {
                if let changes = extra.model.changes {
                    let found = extraPullRequest(extra.repository.root, changes.branch)
                    ReviewBranchCard(changes: changes, status: extra.model.status ?? .unknown, pullRequest: found.map(\.pullRequest), detail: found?.pullRequest.flatMap { extra.model.pullRequestDetails[$0.number] }, isClaudeLive: store.liveBySession[sessionID] != nil, createPullRequest: nil)
                        .listRowInsets(EdgeInsets(top: 0, leading: -7.5 - inset, bottom: 6, trailing: -8))
                    stackedRows(changes, in: extra.model, root: extra.repository.root, indent: inset)
                } else {
                    Text(extra.model.error == nil ? "Loading changes…" : "Can’t read changes")
                        .foregroundStyle(theme.secondary)
                }
            } header: {
                GroupHeader(title: extra.repository.name, help: extra.repository.folder, count: nil) { EmptyView() } accessory: { _ in
                    ReviewRepositoryAccessory(branch: extra.model.changes?.branch, base: extra.model.changes.flatMap { $0.isDefaultBranch ? nil : $0.base }, pullRequests: store.pullRequests(inRoot: extra.repository.root, of: sessionID, branch: extra.model.changes?.branch).filter { !repositoryExpansion(extra.repository.root).wrappedValue || $0.number != extra.model.changes.flatMap { extraPullRequest(extra.repository.root, $0.branch) }?.pullRequest?.number })
                }
            }
        }
    }

    @ViewBuilder
    private func stackedRows(_ changes: ReviewChanges, in model: ReviewModel, root: String?, indent: Double) -> some View {
        if changes.uncommitted.isEmpty, changes.committed.isEmpty {
            Text(changes.isDefaultBranch || changes.base == nil ? "No uncommitted changes on \(changes.branch)" : "No changes, \(changes.branch) matches \(changes.base ?? "")")
                .foregroundStyle(theme.secondary)
        }
        if !changes.uncommitted.isEmpty {
            ReviewSubheading(title: "Uncommitted", files: changes.uncommitted, indent: indent)
            changeRows(changes.uncommitted, compare: .uncommitted, changes: changes, in: model, root: root)
        }
        if !changes.committed.isEmpty {
            ReviewSubheading(title: "Committed", files: changes.committed, indent: indent)
            changeRows(changes.committed, compare: .committed, changes: changes, in: model, root: root)
        }
    }

    private var filesHeader: some View {
        Section(isExpanded: expansion(of: "files")) {} header: {
            GroupHeader(title: "Files", help: "The repository’s files", count: nil) { EmptyView() } accessory: { _ in EmptyView() }
        }
    }

    private func expansion(of id: String) -> Binding<Bool> {
        Binding {
            !collapsedSections.split(separator: ",").contains { $0 == id }
        } set: { expanded in
            let others = collapsedSections.split(separator: ",").filter { $0 != id }.map(String.init)
            collapsedSections = (expanded ? others : others + [id]).joined(separator: ",")
        }
    }

    private var comments: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(owners.flatMap { owner in owner.model.comments.map { (owner: owner, comment: $0) } }, id: \.comment.id) { owner, comment in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(owner.repository.map { "\($0.name):" } ?? "")\(comment.path):\(comment.endLine > comment.line ? "\(comment.line)-\(comment.endLine)" : "\(comment.line)")\(comment.compare == .committed ? ", committed" : "")")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondary)
                                Text(comment.text)
                                    .lineLimit(3)
                            }
                            .contentShape(.rect)
                            .onTapGesture(count: 2) {
                                owner.model.open(ReviewDocument(path: comment.path, compare: comment.compare))
                                owner.model.editingComment = comment.id
                            }
                            Spacer(minLength: 4)
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
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)

            let commentCount = owners.reduce(0) { $0 + $1.model.comments.count }
            Button("Send \(commentCount) \(commentCount == 1 ? "Comment" : "Comments")", action: sendComments)
                .frame(maxWidth: .infinity)
                .padding(10)
        }
    }

    private var pullRequest: (repository: String, pullRequest: PullRequest?)? {
        model.changes.flatMap { store.pullRequest(in: store.sessionsByID[sessionID]?.checkout ?? model.folder, branch: $0.branch) }
    }

    private func loadPullRequestDetail() async {
        guard let pullRequest, let number = pullRequest.pullRequest?.number else { return }

        await model.loadPullRequestDetail(repository: pullRequest.repository, number: number)
    }

    private func header(_ changes: ReviewChanges) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(changes.isDefaultBranch || changes.base == nil ? "\(changes.branch), uncommitted only" : changes.branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 48, alignment: .leading)
                if !changes.isDefaultBranch, let base = changes.base {
                    let pullRequestBase = pullRequest?.pullRequest?.baseRefName
                    Menu {
                        Picker("Compare Against", selection: Binding(get: { base }, set: { model.pickBase($0) })) {
                            ForEach(changes.bases, id: \.ref) { candidate in
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
                    .layoutPriority(1)
                    .help("Compare against…")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(theme.branch)
            Spacer(minLength: 4)
            if let fetchError = changes.fetchError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.needsYou)
                    .help("Couldn’t fetch, comparing local refs: \(fetchError)")
                    .accessibilityLabel("Fetch failed")
            }
            if let error = model.error {
                let failure = failure(error)
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.needsYou)
                    .help("Couldn’t refresh, showing the last changes: \(failure.detail ?? failure.description)")
                    .accessibilityLabel("Refresh failed")
            }
            if !changes.uncommitted.isEmpty || !changes.committed.isEmpty {
                Button(changesAsTree ? "View as List" : "View as Tree", systemImage: changesAsTree ? "list.bullet" : "list.bullet.indent") { changesAsTree.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(changesAsTree ? "View as List" : "View as Tree")
            }
            refreshButton
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
            .labelStyle(.iconOnly)
            .disabled(model.isLoading)
            .help("Refresh")
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
        guard store.liveBySession[sessionID] != nil, let terminal = store.tab(forSession: sessionID)?.terminal, terminal.paste(text: prompt) else {
            model.notice = "Claude isn’t running in this tab; comments kept"
            return
        }

        for owner in owners { owner.model.comments = [] }
        terminal.requestFocus()
    }

    private func createPullRequest() {
        let base = model.changes.flatMap { $0.base == $0.defaultBase ? nil : $0.base }.map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
        let prompt = base.map { "Push this branch and open a pull request for it against \($0) with gh (--base \($0))." } ?? "Push this branch and open a pull request for it with gh."
        guard store.liveBySession[sessionID] != nil, let terminal = store.tab(forSession: sessionID)?.terminal, terminal.paste(text: prompt) else {
            model.notice = "Claude isn’t running in this tab"
            return
        }

        terminal.requestFocus()
    }
}

private struct ReviewRowChrome: ViewModifier {
    let document: ReviewDocument?
    let model: ReviewModel
    @State private var isHovering = false
    @Environment(Store.self) private var store

    private func open(_ document: ReviewDocument) {
        model.open(document.compare == nil ? model.workingDocument(document.path) : ReviewDocument(path: document.path, compare: document.compare))
        if NSApp.currentEvent?.clickCount == 2 { model.selectedTabID.map(model.keep) }
    }

    func body(content: Content) -> some View {
        let isSelected = document.map { document in
            store.reviewModel.map { $0 === model } ?? true && model.selectedDocument.map { $0.path == document.path && $0.compare == document.compare } ?? false
        } ?? false
        content
            .contentShape(.rect)
            .onTapGesture { document.map(open) }
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .listRowBackground(RowFill(opacity: isSelected ? 0.1 : isHovering ? 0.05 : 0))
    }
}

private struct ReviewChangeRow: View {
    let file: ReviewFile
    let model: ReviewModel
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle([ReviewFile.Status.added: theme.working, .modified: theme.needsYou, .deleted: theme.closed, .renamed: theme.branch][file.status] ?? theme.secondary)
            Text((file.path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.regular)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if let additions = file.additions, additions > 0 {
                    Text("+\(additions)").foregroundStyle(theme.working)
                }
                if let deletions = file.deletions, deletions > 0 {
                    Text("−\(deletions)").foregroundStyle(theme.closed)
                }
            }
            .fixedSize()
            ZStack {
                if file.status != .deleted {
                    Button("Open File", systemImage: "doc") { model.open(ReviewDocument(path: file.path, compare: nil)) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(theme.secondary)
                        .help("Open File")
                }
            }
            .frame(width: 16, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }
}

private struct ReviewFileNode: View {
    let node: ReviewFileTree
    let compare: ReviewCompare?
    let changes: ReviewChanges
    let model: ReviewModel
    var root: String?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { Self(node: $0, compare: compare, changes: changes, model: model, root: root) }
            } label: {
                Button { isExpanded.wrappedValue.toggle() } label: {
                    label
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowInsets(.vertical, 0)
                .modifier(ReviewRowChrome(document: nil, model: model))
            }
        } else if let compare, let file = (compare == .committed ? changes.committed : changes.uncommitted).first(where: { $0.path == node.path }) {
            let document = ReviewDocument(path: node.path, compare: compare, root: root)
            ReviewChangeRow(file: file, model: model)
                .padding(.vertical, 5)
                .listRowInsets(.vertical, 0)
                .modifier(ReviewRowChrome(document: document, model: model))
        } else {
            let document = ReviewDocument(path: node.path, compare: nil)
            label
                .modifier(ReviewRowChrome(document: document, model: model))
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
                .foregroundStyle(status.flatMap { [ReviewFile.Status.added: theme.working, .modified: theme.needsYou, .deleted: theme.closed, .renamed: theme.branch][$0] } ?? theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.regular)
        } icon: {
            Image(systemName: node.children == nil ? "doc" : "folder")
                .foregroundStyle(theme.secondary)
        }
        .help(node.path)
    }
}

private struct ReviewFilesSplit<Changes: View, Files: View>: NSViewRepresentable {
    let changes: Changes
    let files: Files
    let layout: ReviewFilesSplitView.Layout
    @Binding var filesHeight: Double
    let divider: NSColor

    func makeNSView(context _: Context) -> ReviewFilesSplitView {
        let split = ReviewFilesSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = split
        let changesView = NSHostingView(rootView: changes)
        let filesView = NSHostingView(rootView: files)
        changesView.sizingOptions = []
        filesView.sizingOptions = []
        split.addSubview(changesView)
        split.addSubview(filesView)
        return split
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: ReviewFilesSplitView, context _: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ split: ReviewFilesSplitView, context _: Context) {
        (split.subviews.first as? NSHostingView<Changes>)?.rootView = changes
        (split.subviews.last as? NSHostingView<Files>)?.rootView = files
        split.divider = divider
        split.dragged = { filesHeight = $0 }
        guard split.layout != layout || split.filesHeight != filesHeight else { return }

        split.layout = layout
        split.filesHeight = filesHeight
        split.resizeSubviews(withOldSize: split.bounds.size)
        // NSSplitView's divider is a sublayer it positions and colours in layout, never in draw.
        split.needsLayout = true
    }
}

private final class ReviewFilesSplitView: NSSplitView, NSSplitViewDelegate {
    enum Layout: Equatable {
        case split
        case filesCollapsed(CGFloat)
        case changesCollapsed(CGFloat)
    }

    static let minimum = 80.0

    var layout = Layout.split
    var filesHeight = 0.0
    var divider = NSColor.separatorColor {
        didSet { needsLayout = true }
    }

    var dragged: (Double) -> Void = { _ in }

    override var dividerColor: NSColor { divider }

    override func mouseDown(with event: NSEvent) {
        let before = subviews.last?.frame.height
        super.mouseDown(with: event)
        guard layout == .split, let after = subviews.last?.frame.height, after != before else { return }

        dragged(after)
    }

    func splitView(_: NSSplitView, resizeSubviewsWithOldSize _: NSSize) {
        guard let changes = subviews.first, let files = subviews.last else { return }

        let available = max(bounds.height - dividerThickness, 0)
        let height = switch layout {
        case .split: min(max(filesHeight > 0 ? filesHeight : available * 0.4, Self.minimum), max(available - Self.minimum, Self.minimum))
        case let .filesCollapsed(header): header
        case let .changesCollapsed(headers): available - headers
        }
        let filesHeight = min(max(height, 0), available)
        changes.frame = NSRect(x: 0, y: 0, width: bounds.width, height: available - filesHeight)
        files.frame = NSRect(x: 0, y: available - filesHeight + dividerThickness, width: bounds.width, height: filesHeight)
    }

    func splitView(_: NSSplitView, constrainMinCoordinate _: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        Self.minimum
    }

    func splitView(_: NSSplitView, constrainMaxCoordinate _: CGFloat, ofSubviewAt _: Int) -> CGFloat {
        bounds.height - dividerThickness - Self.minimum
    }

    func splitView(_: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect _: NSRect, ofDividerAt _: Int) -> NSRect {
        layout == .split ? proposedEffectiveRect.insetBy(dx: 0, dy: -3) : .zero
    }
}

private struct ReviewBranchCard: View {
    let changes: ReviewChanges
    let status: ReviewBranchStatus
    let pullRequest: PullRequest??
    let detail: PullRequestDetail?
    let isClaudeLive: Bool
    let createPullRequest: (() -> Void)?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if changes.isDefaultBranch || changes.base == nil {
                Text(changes.uncommitted.isEmpty ? "No uncommitted changes on \(changes.branch)" : "Uncommitted changes on \(changes.branch)")
                    .fontWeight(.semibold)
                pushState
                    .font(.caption)
            } else {
                let found = pullRequest ?? nil
                if pullRequest != nil {
                    let color = found?.state.color(in: theme) ?? theme.secondary
                    HStack(spacing: 6) {
                        Label(found?.state.rawValue ?? "No pull request", systemImage: found.map { [PullRequestState.merged: "arrow.triangle.merge", .closed: "xmark.circle"][$0.state] ?? "arrow.triangle.pull" } ?? "arrow.triangle.branch")
                            .labelStyle(CompactLabel())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.16), in: .rect(cornerRadius: 4))
                            .fixedSize()
                        if let found {
                            Text(verbatim: "#\(found.number)")
                                .font(.caption.monospaced())
                                .foregroundStyle(theme.secondary)
                            Spacer(minLength: 4)
                            Link(destination: found.url) {
                                Label("Open on GitHub", systemImage: "arrow.up.right.square")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Open on GitHub")
                        }
                    }
                }
                if let found {
                    Text(found.title)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .help(found.title)
                } else {
                    Text(status.ahead == 0 ? "No commits yet" : "\(status.ahead) \(status.ahead == 1 ? "commit" : "commits") ahead of \(changes.base ?? "")")
                        .fontWeight(.semibold)
                }
                HStack(spacing: 10) {
                    if found == nil {
                        Text("↑\(status.ahead) ↓\(status.behind)")
                            .monospaced()
                            .help("\(status.ahead) ahead of \(changes.base ?? ""), \(status.behind) behind")
                    }
                    if let total = changes.total {
                        Text("+\(total.additions) −\(total.deletions)")
                            .monospacedDigit()
                            .help("Changes against \(changes.base ?? ""), uncommitted included")
                    }
                    if found == nil, status.ahead > 0 {
                        pushState
                    }
                    if let checks = detail?.checks {
                        let failed = checks.state == .failed
                        let running = checks.state == .running
                        Label(failed ? "\(checks.failed) failed" : running ? "\(checks.running) running" : "Checks passed", systemImage: failed ? "xmark" : running ? "clock" : "checkmark")
                            .foregroundStyle(failed ? theme.closed : running ? theme.needsYou : theme.working)
                            .help("Checks: \(checks.passed) passed, \(checks.failed) failed, \(checks.running) running")
                    }
                    if let detail {
                        Label("\(detail.unresolvedThreads) open", systemImage: "bubble.left")
                            .help("Unresolved review threads")
                    }
                }
                .labelStyle(CompactLabel())
                .font(.caption)
                .foregroundStyle(theme.secondary)
            }
            if (pullRequest ?? nil) == nil, !status.commits.isEmpty {
                commits
            }
            if let createPullRequest, pullRequest != nil, (pullRequest ?? nil) == nil, !changes.isDefaultBranch, changes.base != nil, status.ahead > 0 {
                Button("Create Pull Request…", action: createPullRequest)
                    .frame(maxWidth: .infinity)
                    .disabled(!isClaudeLive)
                    .help(isClaudeLive ? "Paste a prompt asking Claude to push this branch and open a pull request" : "Claude isn’t running in this tab")
                    .padding(.top, 4)
            }
        }
        .lineLimit(1)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.foreground.opacity(0.05), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.foreground.opacity(0.13)))
    }

    private var pushState: some View {
        Group {
            if let upstream = status.upstream, upstream.ahead > 0 {
                Label("\(upstream.ahead) not pushed", systemImage: "arrow.up")
                    .foregroundStyle(theme.needsYou)
                    .help("\(upstream.ahead) \(upstream.ahead == 1 ? "commit" : "commits") not pushed to \(upstream.name)")
            } else if let upstream = status.upstream, upstream.behind > 0 {
                Label("\(upstream.behind) behind \(upstream.name)", systemImage: "arrow.down")
                    .foregroundStyle(theme.needsYou)
            } else if let upstream = status.upstream {
                Label("Up to date with \(upstream.name)", systemImage: "checkmark")
                    .foregroundStyle(theme.working)
            } else {
                Label(changes.isDefaultBranch || changes.base == nil ? "No upstream" : "Not pushed, no upstream", systemImage: "arrow.up")
                    .foregroundStyle(theme.needsYou)
                    .help("\(changes.branch) has no upstream branch")
            }
        }
        .labelStyle(CompactLabel())
    }

    private var commits: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(status.commits.prefix(5), id: \.sha) { commit in
                HStack(spacing: 7) {
                    Circle()
                        .fill(commit.isPushed ? theme.secondary : .clear)
                        .strokeBorder(commit.isPushed ? .clear : theme.needsYou, lineWidth: 1.25)
                        .frame(width: 7, height: 7)
                        .help(commit.isPushed ? "Pushed" : "Not pushed")
                    Text(commit.sha)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.secondary)
                    Text(commit.subject)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(age(since: commit.date))
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                }
                .frame(height: 22)
                .help(commit.subject)
            }
            if status.commits.count > 5 {
                Text("\(status.commits.count - 5) more")
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                    .frame(height: 22)
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Hairline(axis: .horizontal) }
        .padding(.top, 2)
    }
}

struct ReviewDiffColumn: View {
    let store: Store
    @AppStorage(ReviewStyle.colorSchemeKey) private var colorScheme = ReviewColorScheme.oneDark
    @AppStorage(ReviewStyle.fontFamilyKey) private var fontFamily = ""
    @AppStorage(ReviewStyle.fontSizeKey) private var fontSize = 0.0
    @AppStorage(ReviewStyle.lineHeightKey) private var lineHeight = 1.3
    @AppStorage(GeneralSettings.languageServersKey) private var areLanguageServersEnabled = false
    @AppStorage(ReviewDiffLayout.key) private var diffLayout = ReviewDiffLayout.auto
    @State private var isNarrow = false

    private var isUnified: Bool { diffLayout == .inline || diffLayout == .auto && isNarrow }

    var body: some View {
        let style = ReviewStyle(scheme: colorScheme, fontFamily: fontFamily, fontSize: fontSize, lineHeightMultiple: lineHeight, ghostty: store.theme)
        Group {
            if let model = store.reviewModel, let tab = model.selectedTab {
                let document = tab.document
                let path = document.path
                let isReadOnly = document.compare == .committed && model.changes?.uncommitted.contains { $0.path == path } != false
                VStack(spacing: 0) {
                    HStack {
                        HStack {
                            Button(AppAction.goBack.title, systemImage: AppAction.goBack.symbol) { model.go(by: -1) }
                                .disabled(tab.index == 0)
                                .opacity(tab.index == 0 ? 0.4 : 1)
                                .help("\(AppAction.goBack.title) (⌃-)")
                            Button(AppAction.goForward.title, systemImage: AppAction.goForward.symbol) { model.go(by: 1) }
                                .disabled(tab.index == tab.history.count - 1)
                                .opacity(tab.index == tab.history.count - 1 ? 0.4 : 1)
                                .help("\(AppAction.goForward.title) (⌃⇧-)")
                        }
                        .padding(.leading, 10)
                        ScrollView(.horizontal) {
                            HStack(spacing: 2) {
                                ForEach(model.tabs) { tabButton($0, in: model, style: style) }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                        }
                        .scrollIndicators(.hidden)
                        HStack {
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
                        .padding(.trailing, 10)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color(nsColor: style.secondary))
                    .frame(height: 32)
                    Divider()
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
                            style: style,
                            language: areLanguageServersEnabled ? model.language : nil,
                            reveal: model.reveal.flatMap { $0.document == document ? $0.range : nil },
                            isUnified: isUnified || !model.selectedDocumentHasBothSides,
                            takesFocus: model.focusesEditor,
                            onRevealed: { model.reveal = nil },
                            editsComment: model.editingComment,
                            onEditing: { model.editingComment = nil },
                            onDefinition: model.goToDefinition,
                            workingText: { model.workingText(path) }
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
                    Spacer()
                        .frame(height: 32)
                    Divider()
                    Text("No File Open")
                        .font(.title2)
                        .foregroundStyle(Color(nsColor: style.secondary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { Divider() }
        .foregroundStyle(Color(nsColor: style.foreground))
        .background(Color(nsColor: style.background))
        .environment(\.colorScheme, style.isDark ? .dark : .light)
        .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { isNarrow = $0 }
        .onChange(of: isUnified, initial: true) { store.isReviewDiffUnified = isUnified }
        .environment(store)
        .environment(\.ghosttyTheme, store.theme)
    }

    private func tabButton(_ tab: ReviewTab, in model: ReviewModel, style: ReviewStyle) -> some View {
        let document = tab.document
        let isSelected = tab.id == model.selectedTabID
        let name = (document.path as NSString).lastPathComponent
        let folders = document.path.split(separator: "/").dropLast()
        let namesakes = Set(model.tabs.map(\.document.path)).subtracting([document.path]).filter { ($0 as NSString).lastPathComponent == name }.map { $0.split(separator: "/").dropLast() }
        let parents = namesakes.isEmpty ? [] : (1..<folders.count + 1).lazy.map { folders.suffix($0) }.first { suffix in namesakes.allSatisfy { $0.suffix(suffix.count) != suffix } } ?? folders
        return HStack(spacing: 6) {
            Image(systemName: document.compare == nil ? "doc" : "plus.forwardslash.minus")
                .font(.caption)
                .accessibilityHidden(true)
            Text(name)
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
        .help("\(document.path)\(document.compare == .committed ? " (Committed)" : document.compare == .uncommitted ? " (Uncommitted)" : "")\(tab.isPreview ? ", preview: double-click or edit to keep it" : "")")
        .contextMenu {
            let absolute = model.changes.map { ($0.root as NSString).appendingPathComponent(document.path) }
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
            .disabled(model !== store.primaryReviewModel || !FileManager.default.fileExists(atPath: absolute ?? ""))
            Divider()
            Button("Close") { store.closeDiff(tab: tab.id) }
            Button("Close Others") {
                model.selectedTabID = tab.id
                for other in model.tabs where other.id != tab.id { model.close(other.id) }
            }
            .disabled(model.tabs.count == 1)
        }
    }
}
