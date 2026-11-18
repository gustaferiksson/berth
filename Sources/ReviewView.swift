import BerthCore
import SwiftUI

struct ReviewDocument: Hashable {
    let path: String
    let compare: ReviewCompare?
}

struct ReviewTab: Identifiable {
    let id: UUID
    var history: [ReviewDocument]
    var index: Int
    var isPreview: Bool

    var document: ReviewDocument { history[index] }
}

enum ReviewList: Hashable {
    case changes
    case files
}

@Observable
final class ReviewModel {
    let folder: String
    private(set) var changes: ReviewChanges?
    private(set) var status: ReviewBranchStatus?
    private(set) var tree: [ReviewFileTree] = []
    private(set) var pullRequestDetails: [Int: PullRequestDetail] = [:]
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var contents: [ReviewDocument: ReviewContents] = [:]
    private(set) var language: ReviewLanguage?
    private(set) var tabs: [ReviewTab] = []
    var selectedTabID: UUID?
    var list = ReviewList.changes
    var reveal: (document: ReviewDocument, range: LanguageServerRange)?
    var drafts: [String: String] = [:]
    var comments: [ReviewComment] = []
    var notice: String?
    var focusesEditor = false
    @ObservationIgnored private var loadedTexts: [String: String] = [:]
    @ObservationIgnored private(set) var editors: [String: ReviewTextView] = [:]

    var hasUnsavedEdits: Bool { !drafts.isEmpty }
    var selectedTab: ReviewTab? { tabs.first { $0.id == selectedTabID } }
    var selectedDocument: ReviewDocument? { selectedTab?.document }

    init(folder: String) {
        self.folder = folder
    }

    func load() async {
        isLoading = true
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
            contents = [:]

            let existing = { (document: ReviewDocument) -> ReviewDocument? in
                if let compare = document.compare, (compare == .committed ? changes.committed : changes.uncommitted).contains(where: { $0.path == document.path }) { return document }
                return FileManager.default.fileExists(atPath: URL(filePath: changes.root).appending(path: document.path).path) ? ReviewDocument(path: document.path, compare: nil) : nil
            }
            tabs = tabs.compactMap { tab in
                guard existing(tab.document) != nil else { return nil }
                return ReviewTab(id: tab.id, history: tab.history.compactMap(existing), index: tab.history[..<tab.index].compactMap(existing).count, isPreview: tab.isPreview)
            }
            if selectedTab == nil { selectedTabID = tabs.last?.id }
        } catch {
            changes = nil
            status = nil
            self.error = Self.describe(error)
        }
        isLoading = false
        await loadSelectedContents()
    }

    func open(_ document: ReviewDocument) {
        if let shown = tabs.first(where: { $0.document == document }) {
            selectedTabID = shown.id
            return
        }
        guard let preview = tabs.firstIndex(where: \.isPreview) else {
            let tab = ReviewTab(id: UUID(), history: [document], index: 0, isPreview: true)
            tabs.insert(tab, at: tabs.firstIndex { $0.id == selectedTabID }.map { $0 + 1 } ?? tabs.count)
            selectedTabID = tab.id
            return
        }

        tabs[preview].history = Array(tabs[preview].history.prefix(tabs[preview].index + 1)) + [document]
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
        guard let changes, let document = selectedDocument, contents[document] == nil else { return }

        do {
            let listed = document.compare.flatMap { compare in (compare == .committed ? changes.committed : changes.uncommitted).first { $0.path == document.path } }
            let text = listed == nil ? try ReviewGit.workingTreeText(document.path, in: changes.root) : nil
            let loaded = if let listed, let compare = document.compare { try await ReviewGit.contents(of: listed, compare: compare, in: changes) } else { ReviewContents(original: text, modified: text) }
            contents[document] = loaded
            guard document.compare != .committed else { return }

            if drafts[document.path] == nil { loadedTexts[document.path] = if case let .text(text)? = loaded.modified { text } else { nil } }
            editors[document.path] = editors[document.path] ?? ReviewTextView(usingTextLayoutManager: true)
            setWorkingTreeText(loaded.modified, of: document.path)
        } catch {
            notice = "Couldn’t read \(document.path): \(Self.describe(error))"
        }
    }

    func goToDefinition(_ location: LanguageServerLocation) {
        let target = location.url.resolvingSymlinksInPath().path
        guard let root = changes.map({ URL(filePath: $0.root).resolvingSymlinksInPath().path + "/" }), target.hasPrefix(root) else { return }

        let path = String(target.dropFirst(root.count))
        let document = selectedDocument.flatMap { $0.path == path ? $0 : nil } ?? workingDocument(path)
        reveal = (document, location.range)
        open(document)
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
        setWorkingTreeText(.text(text), of: path)
    }

    private func setWorkingTreeText(_ text: ReviewText?, of path: String) {
        for document in contents.keys where document.path == path && document.compare != .committed {
            contents[document] = contents[document].map { ReviewContents(original: document.compare == nil ? text : $0.original, modified: text) }
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard case let ReviewGitError.git(_, message) = error else { return String(describing: error) }
        return message
    }
}

struct ReviewPanel: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let model = store.reviewModel, let sessionID = store.tabs.first(where: { $0.id == store.selectedTabID })?.sessionID {
            ReviewFileList(sessionID: sessionID, model: model)
                .id(sessionID)
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

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await model.load() }
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
                if let status = model.status {
                    ReviewBranchCard(changes: changes, status: status, pullRequest: pullRequest.map(\.pullRequest), detail: pullRequest?.pullRequest.flatMap { model.pullRequestDetails[$0.number] }, isClaudeLive: store.liveBySession[sessionID] != nil, createPullRequest: createPullRequest)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                Picker("List", selection: $model.list) {
                    Text("Changes").tag(ReviewList.changes)
                    Text("Files").tag(ReviewList.files)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                Group {
                    if model.list == .files {
                        filesList(changes)
                    } else {
                        changesList(changes)
                    }
                }
                .listStyle(.sidebar)
                .environment(\.sidebarRowSize, .small)
                .scrollContentBackground(.hidden)
                .background(OverlayScroller())

                if !model.comments.isEmpty {
                    Hairline(axis: .horizontal)
                    comments
                }
            }
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Can’t Review Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                refreshButton
            }
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading changes…")
            }
        }
    }

    private func changesList(_ changes: ReviewChanges) -> some View {
        List(selection: Binding(get: { model.selectedDocument }, set: { $0.map(model.open) })) {
            if changes.uncommitted.isEmpty, changes.committed.isEmpty {
                Text(changes.isDefaultBranch || changes.base == nil ? "No uncommitted changes on \(changes.branch)" : "No changes, \(changes.branch) matches \(changes.base ?? "")")
                    .foregroundStyle(theme.secondary)
            }
            if !changes.uncommitted.isEmpty {
                Section {
                    ForEach(changes.uncommitted, id: \.path) { fileRow($0).tag(ReviewDocument(path: $0.path, compare: .uncommitted)) }
                } header: {
                    sectionHeader("Uncommitted", count: changes.uncommitted.count, detail: "+\(changes.uncommitted.compactMap(\.additions).reduce(0, +)) −\(changes.uncommitted.compactMap(\.deletions).reduce(0, +))")
                }
            }
            if !changes.committed.isEmpty {
                Section {
                    ForEach(changes.committed, id: \.path) { fileRow($0).tag(ReviewDocument(path: $0.path, compare: .committed)) }
                } header: {
                    sectionHeader("Committed", count: changes.committed.count, detail: model.status.map { "\($0.commits.count) \($0.commits.count == 1 ? "commit" : "commits")" } ?? "")
                }
            }
        }
        .contextMenu(forSelectionType: ReviewDocument.self) { _ in
        } primaryAction: { documents in
            guard let document = documents.first else { return }
            model.open(document)
            model.selectedTabID.map(model.keep)
        }
    }

    private func filesList(_ changes: ReviewChanges) -> some View {
        List(model.tree, children: \.children, selection: Binding(get: { model.selectedDocument.flatMap { $0.compare == .committed ? nil : $0.path } }, set: { $0.map { model.open(model.workingDocument($0)) } })) { node in
            let status = (changes.uncommitted.first { $0.path == node.path } ?? changes.committed.first { $0.path == node.path })?.status
            Label(node.name, systemImage: node.children == nil ? "doc" : "folder")
                .foregroundStyle(status.flatMap { [ReviewFile.Status.added: theme.working, .modified: theme.needsYou, .deleted: theme.closed, .renamed: theme.branch][$0] } ?? theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(node.path)
                .selectionDisabled(node.children != nil)
        }
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { paths in
            guard let path = paths.first else { return }
            model.open(model.workingDocument(path))
            model.selectedTabID.map(model.keep)
        }
    }

    private func sectionHeader(_ title: String, count: Int, detail: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(count)")
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 4)
            Text(detail)
                .foregroundStyle(theme.secondary)
        }
        .monospacedDigit()
        .padding(.trailing, 12)
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
            refreshButton
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task {
                await model.load()
                if let repository = pullRequest?.repository, let branch = model.changes?.branch { await store.fetchPullRequests([PullRequestBranch(repository: repository, branch: branch)]) }
                await loadPullRequestDetail()
            }
        }
        .labelStyle(.iconOnly)
        .disabled(model.isLoading)
        .help("Refresh")
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
    @State private var isUnified = false

    var body: some View {
        let style = ReviewStyle(scheme: colorScheme, fontFamily: fontFamily, fontSize: fontSize, lineHeightMultiple: lineHeight, ghostty: store.theme)
        if let model = store.reviewModel, let tab = model.selectedTab {
            let document = tab.document
            let path = document.path
            let isCommitted = document.compare == .committed
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
                    Button("Back", systemImage: "chevron.backward") { model.go(by: -1) }
                        .disabled(tab.index == 0)
                    Button("Forward", systemImage: "chevron.forward") { model.go(by: 1) }
                        .disabled(tab.index == tab.history.count - 1)
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
                    }
                    Spacer(minLength: 8)
                    if !isCommitted, let draft = model.drafts[path] {
                        Button("Save") { model.save(draft, to: path) }
                            .keyboardShortcut("s")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal, 8)
                .frame(height: 36)
                Divider()
                if let contents = model.contents[document], isCommitted || model.editors[path] != nil {
                    ReviewDiffPane(
                        path: path,
                        compare: document.compare,
                        contents: contents,
                        editor: isCommitted ? nil : model.editors[path],
                        draft: isCommitted ? .constant(nil) : Binding(get: { model.drafts[path] }, set: { draft in
                            model.drafts[path] = draft
                            model.keep(tab.id)
                        }),
                        comments: Bindable(model).comments,
                        style: style,
                        language: areLanguageServersEnabled && !isCommitted ? model.language : nil,
                        reveal: model.reveal.flatMap { $0.document == document ? $0.range : nil },
                        isUnified: isUnified || document.compare == nil,
                        takesFocus: model.focusesEditor,
                        onRevealed: { model.reveal = nil },
                        onDefinition: model.goToDefinition
                    )
                    .id(document)
                    .task(id: model.focusesEditor) { model.focusesEditor = false }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(Color(nsColor: style.foreground))
            .background(Color(nsColor: style.background))
            .environment(\.colorScheme, style.isDark ? .dark : .light)
            .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { isUnified = $0 }
            .environment(store)
            .environment(\.ghosttyTheme, store.theme)
        }
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
