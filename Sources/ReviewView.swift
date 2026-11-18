import BerthCore
import SwiftUI

@Observable
final class ReviewModel {
    let folder: String
    private(set) var snapshot: ReviewSnapshot?
    private(set) var branch: (changes: ReviewChanges, status: ReviewBranchStatus)?
    private(set) var pullRequestDetails: [Int: PullRequestDetail] = [:]
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var contents: [String: ReviewContents] = [:]
    private(set) var language: ReviewLanguage?
    var selectedPath: String?
    var reveal: (path: String, range: LanguageServerRange)?
    var drafts: [String: String] = [:]
    var comments: [ReviewComment] = []
    var notice: String?
    @ObservationIgnored private var loadedTexts: [String: String] = [:]
    @ObservationIgnored private(set) var editors: [String: ReviewTextView] = [:]

    var hasUnsavedEdits: Bool { !drafts.isEmpty }

    init(folder: String) {
        self.folder = folder
    }

    func load() async {
        isLoading = true
        do {
            let snapshot = try await ReviewGit.snapshot(in: folder)
            self.snapshot = snapshot
            error = nil
            if language?.root != snapshot.root {
                language?.stop()
                language = ReviewLanguage(root: snapshot.root)
            }
            contents = [:]
            if let path = selectedPath, !snapshot.files.contains(where: { $0.path == path }), !FileManager.default.fileExists(atPath: URL(filePath: snapshot.root).appending(path: path).path) { selectedPath = nil }

            let changes = try? await ReviewGit.changes(in: folder)
            branch = if let changes, let status = try? await ReviewGit.branchStatus(of: changes) { (changes, status) } else { nil }
        } catch {
            snapshot = nil
            self.error = Self.describe(error)
        }
        isLoading = false
        await loadSelectedContents()
    }

    func loadPullRequestDetail(repository: String, number: Int) async {
        let detail = Snapshot.output != nil ? Snapshot.fixturePullRequestDetail : await Task.detached { PullRequestStatus.detail(repository: repository, number: number) }.value
        if let detail { pullRequestDetails[number] = detail }
    }

    func loadSelectedContents() async {
        guard let snapshot, let path = selectedPath, contents[path] == nil else { return }

        do {
            let file = snapshot.files.first { $0.path == path }
            let unchanged = file == nil ? try ReviewGit.workingTreeText(path, in: snapshot.root) : nil
            let loaded = if let file { try await ReviewGit.contents(of: file, in: snapshot) } else { ReviewContents(original: unchanged, modified: unchanged) }
            if drafts[path] == nil { loadedTexts[path] = if case let .text(text)? = loaded.modified { text } else { nil } }
            editors[path] = editors[path] ?? ReviewTextView(usingTextLayoutManager: true)
            contents[path] = loaded
        } catch {
            notice = "Couldn’t read \(path): \(Self.describe(error))"
        }
    }

    func goToDefinition(_ location: LanguageServerLocation) {
        let target = location.url.resolvingSymlinksInPath().path
        guard let root = snapshot.map({ URL(filePath: $0.root).resolvingSymlinksInPath().path + "/" }), target.hasPrefix(root) else { return }

        let path = String(target.dropFirst(root.count))
        reveal = (path, location.range)
        selectedPath = path
    }

    func save(_ text: String, to path: String) {
        guard let snapshot, snapshot.files.first(where: { $0.path == path })?.status != .deleted else {
            notice = "\(path) is read only here"
            return
        }
        guard let expected = loadedTexts[path], (try? ReviewGit.workingTreeText(path, in: snapshot.root)) == .text(expected) else {
            notice = "\(path) changed on disk; reload before saving"
            return
        }

        do {
            try ReviewGit.save(text, to: path, in: snapshot.root)
        } catch {
            notice = "Couldn’t save \(path): \(Self.describe(error))"
            return
        }
        loadedTexts[path] = text
        drafts[path] = nil
        contents[path] = contents[path].map { ReviewContents(original: $0.original, modified: .text(text)) }
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
            .task(id: model.selectedPath) { await model.loadSelectedContents() }
            .task(id: pullRequest?.pullRequest?.number) { await loadPullRequestDetail() }
            .alert("Review", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }), presenting: model.notice) { _ in
            } message: { notice in
                Text(notice)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = model.snapshot, !snapshot.files.isEmpty {
            VStack(spacing: 0) {
                header(snapshot)
                if let branch = model.branch {
                    ReviewBranchCard(changes: branch.changes, status: branch.status, pullRequest: pullRequest.map(\.pullRequest), detail: pullRequest?.pullRequest.flatMap { model.pullRequestDetails[$0.number] })
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                List(snapshot.files, id: \.path, selection: $model.selectedPath) { file in
                    fileRow(file)
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
        } else if let snapshot = model.snapshot {
            ContentUnavailableView {
                Label("No Changes", systemImage: "checkmark")
            } description: {
                Text("\(snapshot.branch) matches \(snapshot.base).")
            } actions: {
                refreshButton
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

    private func fileRow(_ file: ReviewFile) -> some View {
        let statusColor = [ReviewFile.Status.added: theme.working, .modified: theme.needsYou, .deleted: theme.closed, .renamed: theme.branch][file.status]
        return HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor ?? theme.secondary)
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
                                Text("\(comment.path):\(comment.endLine > comment.line ? "\(comment.line)-\(comment.endLine)" : "\(comment.line)")")
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
        model.snapshot.flatMap { store.pullRequest(in: store.sessionsByID[sessionID]?.checkout ?? model.folder, branch: $0.branch) }
    }

    private func loadPullRequestDetail() async {
        guard let pullRequest, let number = pullRequest.pullRequest?.number else { return }
        await model.loadPullRequestDetail(repository: pullRequest.repository, number: number)
    }

    private func header(_ snapshot: ReviewSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("\(snapshot.branch) → \(snapshot.base)")
                .font(.caption.monospaced())
                .foregroundStyle(theme.branch)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let fetchError = snapshot.fetchError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.needsYou)
                    .help("Couldn’t fetch \(snapshot.base), comparing local refs: \(fetchError)")
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
                await loadPullRequestDetail()
            }
        }
        .labelStyle(.iconOnly)
        .disabled(model.isLoading)
        .help("Refresh")
    }

    private func sendComments() {
        let prompt = ReviewComment.prompt(for: model.comments, branch: model.snapshot?.branch ?? "HEAD", base: model.snapshot?.base ?? "HEAD")
        guard store.liveBySession[sessionID] != nil, let terminal = store.tab(forSession: sessionID)?.terminal, terminal.paste(text: prompt) else {
            model.notice = "Claude isn’t running in this tab; comments kept"
            return
        }

        model.comments = []
        terminal.requestFocus()
    }
}

private struct ReviewBranchCard: View {
    let changes: ReviewChanges
    let status: ReviewBranchStatus
    let pullRequest: PullRequest??
    let detail: PullRequestDetail?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if changes.isDefaultBranch || changes.base == nil {
                Text("Uncommitted changes on \(changes.branch)")
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
        if let model = store.reviewModel, let path = model.selectedPath {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(path)
                        .foregroundStyle(Color(nsColor: style.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let draft = model.drafts[path] {
                        Button("Save") { model.save(draft, to: path) }
                            .keyboardShortcut("s")
                    }
                    Button("Close Diff", systemImage: "xmark", action: store.closeDiff)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Close Diff (⌘W)")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 36)
                Divider()
                if let contents = model.contents[path], let editor = model.editors[path] {
                    ReviewDiffPane(
                        path: path,
                        contents: contents,
                        editor: editor,
                        draft: Bindable(model).drafts[path],
                        comments: Bindable(model).comments,
                        style: style,
                        language: areLanguageServersEnabled ? model.language : nil,
                        reveal: model.reveal.flatMap { $0.path == path ? $0.range : nil },
                        isUnified: isUnified,
                        onRevealed: { model.reveal = nil },
                        onDefinition: model.goToDefinition
                    )
                    .id(path)
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
}
