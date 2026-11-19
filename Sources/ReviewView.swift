import BerthCore
import SwiftUI

struct ReviewDocument: Hashable {
    let path: String
    let compare: ReviewCompare?
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
    var notice: String?
    var movedFolder: String?
    var focusesEditor = false
    var expandedFolders: Set<String> = []
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var queuedLoad: Task<Void, Never>?
    @ObservationIgnored private(set) var loadCount = 0
    @ObservationIgnored private var loadedTexts: [String: String] = [:]
    @ObservationIgnored private(set) var editors: [String: ReviewTextView] = [:]
    @ObservationIgnored private var savedFromCommitted: Set<String> = []

    var hasUnsavedEdits: Bool { !drafts.isEmpty }
    var selectedTab: ReviewTab? { tabs.first { $0.id == selectedTabID } }
    var selectedDocument: ReviewDocument? { selectedTab?.document }

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
            let changes = try await ReviewGit.changes(in: folder)
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

    func open(_ document: ReviewDocument) {
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
        if let model = store.reviewModel, let sessionID = store.tabs.first(where: { $0.id == store.selectedTabID })?.sessionID {
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
    @State private var changesContentHeight = 0.0
    @State private var filesContentHeight = 0.0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await model.load() }
            .onChange(of: model.hasUnsavedEdits || !model.comments.isEmpty) { store.prepareReviewModel() }
            .task(id: model.selectedDocument) { await model.loadSelectedContents() }
            .task(id: pullRequest?.pullRequest?.number) { await loadPullRequestDetail() }
            .alert("Review", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in
            } message: { notice in
                Text(notice)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let changes = model.changes {
            VStack(spacing: 0) {
                header(changes)
                if let movedFolder = model.movedFolder {
                    Label("This session moved to \((movedFolder as NSString).abbreviatingWithTildeInPath). Save or undo your edits and send or delete your comments to follow it.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(theme.needsYou)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
                if let status = model.status {
                    ReviewBranchCard(changes: changes, status: status, pullRequest: pullRequest.map(\.pullRequest), detail: pullRequest?.pullRequest.flatMap { model.pullRequestDetails[$0.number] }, isClaudeLive: store.liveBySession[sessionID] != nil, createPullRequest: createPullRequest)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                ReviewFilesSplit(
                    changes: list { changeSections(changes) }
                        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: { changesContentHeight = $1 }
                        .environment(\.ghosttyTheme, theme),
                    files: ScrollViewReader { proxy in
                        list { filesSection(changes) }
                            .onChange(of: model.selectedDocument?.path, initial: true) { _, path in
                                guard let path else { return }
                                model.expandedFolders.formUnion(path.split(separator: "/").dropLast().reduce(into: [String]()) { $0.append(($0.last.map { $0 + "/" } ?? "") + $1) })
                                Task { proxy.scrollTo(path) }
                            }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom } action: { filesContentHeight = $1 }
                    .environment(\.ghosttyTheme, theme),
                    layout: !expansion(of: "files").wrappedValue ? .filesCollapsed(filesContentHeight) : (changes.uncommitted.isEmpty || !expansion(of: "uncommitted").wrappedValue) && (changes.committed.isEmpty || !expansion(of: "committed").wrappedValue) ? .changesCollapsed(changesContentHeight) : .split,
                    filesHeight: $filesPaneHeight,
                    divider: NSColor(theme.foreground.opacity(0.1))
                )

                if !model.comments.isEmpty {
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

    private func list(@ViewBuilder _ sections: () -> some View) -> some View {
        List(selection: Binding(get: { model.selectedDocument }, set: { $0.map { model.open($0.compare == nil ? model.workingDocument($0.path) : $0) } }), content: sections)
            .contextMenu(forSelectionType: ReviewDocument.self) { _ in
            } primaryAction: { documents in
                guard let document = documents.first else { return }
                model.open(document.compare == nil ? model.workingDocument(document.path) : document)
                model.selectedTabID.map(model.keep)
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
            .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func changeSections(_ changes: ReviewChanges) -> some View {
        if changes.uncommitted.isEmpty, changes.committed.isEmpty {
            Text(changes.isDefaultBranch || changes.base == nil ? "No uncommitted changes on \(changes.branch)" : "No changes, \(changes.branch) matches \(changes.base ?? "")")
                .foregroundStyle(theme.secondary)
        }
        if !changes.uncommitted.isEmpty {
            Section(isExpanded: expansion(of: "uncommitted")) {
                ForEach(changes.uncommitted, id: \.path) { fileRow($0).tag(ReviewDocument(path: $0.path, compare: .uncommitted)) }
            } header: {
                GroupHeader(title: "Uncommitted", help: "HEAD to the working tree", count: changes.uncommitted.count, menu: { EmptyView() }) { _ in
                    Text("+\(changes.uncommitted.compactMap(\.additions).reduce(0, +)) −\(changes.uncommitted.compactMap(\.deletions).reduce(0, +))")
                        .monospacedDigit()
                        .foregroundStyle(theme.secondary)
                        .padding(.trailing, 6)
                }
            }
        }
        if !changes.committed.isEmpty {
            Section(isExpanded: expansion(of: "committed")) {
                ForEach(changes.committed, id: \.path) { fileRow($0).tag(ReviewDocument(path: $0.path, compare: .committed)) }
            } header: {
                GroupHeader(title: "Committed", help: "\(changes.base ?? "The base") to HEAD", count: changes.committed.count, menu: { EmptyView() }) { _ in
                    Text(model.status.map { "\($0.commits.count) \($0.commits.count == 1 ? "commit" : "commits")" } ?? "")
                        .foregroundStyle(theme.secondary)
                }
            }
        }
    }

    private func filesSection(_ changes: ReviewChanges) -> some View {
        Section(isExpanded: expansion(of: "files")) {
            ForEach(model.tree) { ReviewFileNode(node: $0, changes: changes, model: model) }
        } header: {
            GroupHeader(title: "Files", help: "The repository’s files", count: nil, menu: { EmptyView() }) { _ in EmptyView() }
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

    private func fileRow(_ file: ReviewFile) -> some View {
        HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle([ReviewFile.Status.added: theme.working, .modified: theme.needsYou, .deleted: theme.closed, .renamed: theme.branch][file.status] ?? theme.secondary)
            Text((file.path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
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

    private var comments: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.comments) { comment in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(comment.path):\(comment.endLine > comment.line ? "\(comment.line)-\(comment.endLine)" : "\(comment.line)")\(comment.compare == .committed ? ", committed" : "")")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondary)
                                Text(comment.text)
                                    .lineLimit(3)
                            }
                            Spacer(minLength: 4)
                            Button("Delete Comment", systemImage: "xmark") {
                                model.comments.removeAll { $0.id == comment.id }
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

            Button("Send \(model.comments.count) \(model.comments.count == 1 ? "Comment" : "Comments")", action: sendComments)
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
            Text(changes.isDefaultBranch || changes.base == nil ? "\(changes.branch), uncommitted only" : "\(changes.branch) → \(changes.base ?? "")")
                .font(.caption.monospaced())
                .foregroundStyle(theme.branch)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let fetchError = changes.fetchError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.needsYou)
                    .help("Couldn’t fetch \(changes.base ?? ""), comparing local refs: \(fetchError)")
            }
            if let error = model.error {
                let failure = failure(error)
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.needsYou)
                    .help("Couldn’t refresh, showing the last changes: \(failure.detail ?? failure.description)")
            }
            refreshButton
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
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
            guard store.reviewModel === model else { return }
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
        let prompt = ReviewComment.prompt(for: model.comments, branch: model.changes?.branch ?? "HEAD", base: model.changes.flatMap { $0.isDefaultBranch ? nil : $0.base } ?? "HEAD")
        guard store.liveBySession[sessionID] != nil, let terminal = store.tab(forSession: sessionID)?.terminal, terminal.paste(text: prompt) else {
            model.notice = "Claude isn’t running in this tab; comments kept"
            return
        }

        model.comments = []
        terminal.requestFocus()
    }

    private func createPullRequest() {
        guard store.liveBySession[sessionID] != nil, let terminal = store.tab(forSession: sessionID)?.terminal, terminal.paste(text: "Push this branch and open a pull request for it with gh.") else {
            model.notice = "Claude isn’t running in this tab"
            return
        }

        terminal.requestFocus()
    }
}

private struct ReviewFileNode: View {
    let node: ReviewFileTree
    let changes: ReviewChanges
    let model: ReviewModel
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: Binding { model.expandedFolders.contains(node.path) } set: { $0 ? model.expandedFolders.formUnion([node.path]) : model.expandedFolders.subtract([node.path]) }) {
                ForEach(children) { ReviewFileNode(node: $0, changes: changes, model: model) }
            } label: {
                Button(action: toggle) {
                    label
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowInsets(.vertical, 0)
                .selectionDisabled()
            }
        } else {
            label.tag(ReviewDocument(path: node.path, compare: nil))
        }
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

    private func toggle() {
        if model.expandedFolders.remove(node.path) == nil { model.expandedFolders.insert(node.path) }
    }
}

private struct ReviewFilesSplit<Changes: View, Files: View>: NSViewRepresentable {
    let changes: Changes
    let files: Files
    let layout: ReviewFilesSplitView.Layout
    @Binding var filesHeight: Double
    let divider: NSColor

    func makeNSView(context: Context) -> ReviewFilesSplitView {
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReviewFilesSplitView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ split: ReviewFilesSplitView, context: Context) {
        (split.subviews.first as? NSHostingView<Changes>)?.rootView = changes
        (split.subviews.last as? NSHostingView<Files>)?.rootView = files
        split.divider = divider
        split.dragged = { filesHeight = $0 }
        guard split.layout != layout || split.filesHeight != filesHeight else { return }

        split.layout = layout
        split.filesHeight = filesHeight
        split.resizeSubviews(withOldSize: split.bounds.size)
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
        didSet { needsDisplay = true }
    }
    var dragged: (Double) -> Void = { _ in }

    override var dividerColor: NSColor { divider }

    override func mouseDown(with event: NSEvent) {
        let before = subviews.last?.frame.height
        super.mouseDown(with: event)
        guard layout == .split, let after = subviews.last?.frame.height, after != before else { return }

        dragged(after)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
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

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        Self.minimum
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        bounds.height - dividerThickness - Self.minimum
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        layout == .split ? proposedEffectiveRect.insetBy(dx: 0, dy: -3) : .zero
    }
}

private struct ReviewBranchCard: View {
    let changes: ReviewChanges
    let status: ReviewBranchStatus
    let pullRequest: PullRequest??
    let detail: PullRequestDetail?
    let isClaudeLive: Bool
    let createPullRequest: () -> Void
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if changes.isDefaultBranch || changes.base == nil {
                Text(changes.uncommitted.isEmpty ? "No uncommitted changes on \(changes.branch)" : "Uncommitted changes on \(changes.branch)")
                    .fontWeight(.semibold)
                pushState
                    .font(.subheadline)
            } else {
                let found = pullRequest ?? nil
                if pullRequest != nil {
                    let color = found?.state.color(in: theme) ?? theme.secondary
                    HStack(spacing: 6) {
                        Label(found?.state.rawValue ?? "No pull request", systemImage: found.map { [PullRequestState.merged: "arrow.triangle.merge", .closed: "xmark.circle"][$0.state] ?? "arrow.triangle.pull" } ?? "arrow.triangle.branch")
                            .labelStyle(CompactLabel())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color.opacity(0.16), in: .capsule)
                            .fixedSize()
                        if let found {
                            Text(verbatim: "#\(found.number)")
                                .font(.subheadline.monospaced())
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
                    if let detail {
                        HStack(spacing: 10) {
                            if let checks = detail.checks {
                                let failed = checks.state == .failed
                                let running = checks.state == .running
                                Label(failed ? "\(checks.failed) failed" : running ? "\(checks.running) running" : "Checks passed", systemImage: failed ? "xmark" : running ? "clock" : "checkmark")
                                    .foregroundStyle(failed ? theme.closed : running ? theme.needsYou : theme.working)
                                    .help("Checks: \(checks.passed) passed, \(checks.failed) failed, \(checks.running) running")
                            }
                            Label("\(detail.unresolvedThreads) open", systemImage: "bubble.left")
                                .help("Unresolved review threads")
                        }
                        .labelStyle(CompactLabel())
                        .font(.subheadline)
                        .foregroundStyle(theme.secondary)
                    }
                } else {
                    Text(status.ahead == 0 ? "No commits yet" : "\(status.ahead) \(status.ahead == 1 ? "commit" : "commits") ahead of \(changes.base ?? "")")
                        .fontWeight(.semibold)
                    HStack(spacing: 10) {
                        Text("↑\(status.ahead) ↓\(status.behind)")
                            .monospaced()
                            .help("\(status.ahead) ahead of \(changes.base ?? ""), \(status.behind) behind")
                        if status.ahead > 0 {
                            pushState
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(theme.secondary)
                }
            }
            if (pullRequest ?? nil) == nil, !status.commits.isEmpty {
                commits
            }
            if pullRequest != nil, (pullRequest ?? nil) == nil, !changes.isDefaultBranch, changes.base != nil, status.ahead > 0 {
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
                        .font(.subheadline.monospaced())
                        .foregroundStyle(theme.secondary)
                    Text(commit.subject)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(age(since: commit.date))
                        .font(.subheadline)
                        .foregroundStyle(theme.secondary)
                }
                .frame(height: 22)
                .help(commit.subject)
            }
            if status.commits.count > 5 {
                Text("\(status.commits.count - 5) more")
                    .font(.subheadline)
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
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(model.tabs) { tabButton($0, in: model, style: style) }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 32)
                    Divider()
                    HStack(spacing: 8) {
                        Button(AppAction.goBack.title, systemImage: AppAction.goBack.symbol) { model.go(by: -1) }
                            .disabled(tab.index == 0)
                            .help("\(AppAction.goBack.title) (⌃-)")
                        Button(AppAction.goForward.title, systemImage: AppAction.goForward.symbol) { model.go(by: 1) }
                            .disabled(tab.index == tab.history.count - 1)
                            .help("\(AppAction.goForward.title) (⌃⇧-)")
                        Text(path)
                            .foregroundStyle(Color(nsColor: style.secondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let compare = document.compare {
                            Text(compare == .committed ? "Committed" : "Uncommitted")
                                .font(.caption)
                                .foregroundStyle(Color(nsColor: style.secondary))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color(nsColor: style.foreground).opacity(0.08), in: .rect(cornerRadius: 4))
                            Button(isUnified ? "Show Side by Side" : "Show Inline", systemImage: isUnified ? "rectangle.split.2x1" : "rectangle") {
                                diffLayout = isUnified ? .sideBySide : .inline
                            }
                            .help(isUnified ? "Show Side by Side" : "Show Inline")
                        }
                        Spacer(minLength: 8)
                        if AppAction.save.isAvailable(in: store) {
                            Button("Save") { AppAction.save.perform(on: store) }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .frame(height: 36)
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
                            isUnified: isUnified || document.compare == nil,
                            takesFocus: model.focusesEditor,
                            onRevealed: { model.reveal = nil },
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
        return HStack(spacing: 6) {
            Image(systemName: document.compare == nil ? "doc" : "plus.forwardslash.minus")
                .font(.caption)
            Text((document.path as NSString).lastPathComponent)
                .italic(tab.isPreview)
                .lineLimit(1)
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
        .help("\(document.path)\(document.compare == .committed ? ", committed" : document.compare == .uncommitted ? ", uncommitted" : "")\(tab.isPreview ? ", preview: double-click or edit to keep it" : "")")
    }
}
