import BerthCore
import SwiftUI

@Observable
final class ReviewModel {
    let folder: String
    private(set) var snapshot: ReviewSnapshot?
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
            if !snapshot.files.contains(where: { $0.path == selectedPath }) { selectedPath = nil }
        } catch {
            snapshot = nil
            self.error = Self.describe(error)
        }
        isLoading = false
        await loadSelectedContents()
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

    private func header(_ snapshot: ReviewSnapshot) -> some View {
        let pullRequest = store.pullRequest(in: store.sessionsByID[sessionID]?.checkout ?? model.folder, branch: snapshot.branch)
        return HStack(alignment: .top, spacing: 8) {
            if let pullRequest {
                let stateColor = pullRequest.state.color(in: theme)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label(pullRequest.state.rawValue, systemImage: [PullRequestState.merged: "arrow.triangle.merge", .closed: "xmark.circle"][pullRequest.state] ?? "arrow.triangle.pull")
                            .labelStyle(CompactLabel())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(stateColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(stateColor.opacity(0.16), in: .capsule)
                            .fixedSize()
                        Text(verbatim: "#\(pullRequest.number)")
                            .foregroundStyle(theme.secondary)
                            .fixedSize()
                    }
                    Text(pullRequest.title)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                    HStack(spacing: 0) {
                        Text("\(snapshot.base) ← ")
                            .foregroundStyle(theme.secondary)
                        Text(snapshot.branch)
                            .foregroundStyle(theme.branch)
                    }
                    .font(.caption.monospaced())
                    .lineLimit(1)
                }
                .layoutPriority(1)
            } else {
                Text("\(snapshot.branch) → \(snapshot.base)")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let fetchError = snapshot.fetchError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.needsYou)
                    .help("Couldn’t fetch \(snapshot.base), comparing local refs: \(fetchError)")
            }
            if let pullRequest {
                Link(destination: pullRequest.url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open on GitHub")
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
            Task { await model.load() }
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

struct ReviewDiffColumn: View {
    let store: Store
    @AppStorage(ReviewStyle.colorSchemeKey) private var colorScheme = ReviewColorScheme.oneDark
    @AppStorage(ReviewStyle.fontFamilyKey) private var fontFamily = ""
    @AppStorage(ReviewStyle.fontSizeKey) private var fontSize = 0.0
    @AppStorage(ReviewStyle.lineHeightKey) private var lineHeight = 1.3
    @AppStorage(GeneralSettings.languageServersKey) private var areLanguageServersEnabled = false

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
            .environment(store)
            .environment(\.ghosttyTheme, store.theme)
        }
    }
}
