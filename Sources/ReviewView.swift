import BerthCore
import SwiftUI

@Observable
final class ReviewModel {
    let folder: String
    private(set) var snapshot: ReviewSnapshot?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var contents: [String: ReviewContents] = [:]
    var selectedPath: String?
    var drafts: [String: String] = [:]
    var comments: [ReviewComment] = []
    var notice: String?
    @ObservationIgnored private var loadedTexts: [String: String] = [:]

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
            contents = [:]
            if !snapshot.files.contains(where: { $0.path == selectedPath }) { selectedPath = snapshot.files.first?.path }
        } catch {
            snapshot = nil
            self.error = Self.describe(error)
        }
        isLoading = false
        await loadSelectedContents()
    }

    func loadSelectedContents() async {
        guard let snapshot, let file = snapshot.files.first(where: { $0.path == selectedPath }), contents[file.path] == nil else { return }

        do {
            let loaded = try await ReviewGit.contents(of: file, in: snapshot)
            if drafts[file.path] == nil { loadedTexts[file.path] = if case let .text(text)? = loaded.modified { text } else { nil } }
            contents[file.path] = loaded
        } catch {
            notice = "Couldn’t read \(file.path): \(Self.describe(error))"
        }
    }

    func save(_ text: String, to path: String) {
        guard let snapshot, snapshot.files.contains(where: { $0.path == path && $0.status != .deleted }) else {
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

struct ReviewView: View {
    let sessionID: String
    @Bindable var model: ReviewModel
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @FocusState private var isFileListFocused: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background ?? .clear)
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
            HStack(spacing: 0) {
                fileColumn(snapshot)
                    .frame(width: 260)
                Hairline(axis: .vertical)
                VStack(spacing: 0) {
                    header(snapshot)
                    Hairline(axis: .horizontal)
                    diff
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

    private func fileColumn(_ snapshot: ReviewSnapshot) -> some View {
        VStack(spacing: 0) {
            List(snapshot.files, id: \.path, selection: $model.selectedPath) { file in
                fileRow(file)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($isFileListFocused)
            .onAppear { isFileListFocused = true }

            if !model.comments.isEmpty {
                Hairline(axis: .horizontal)
                comments
            }
        }
    }

    private func fileRow(_ file: ReviewFile) -> some View {
        let parent = (file.path as NSString).deletingLastPathComponent
        let statusColor = [ReviewFile.Status.added: theme.working, .modified: theme.needsYou, .deleted: theme.closed, .renamed: theme.branch][file.status]
        return HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor ?? theme.secondary)
            Text((file.path as NSString).lastPathComponent)
                .lineLimit(1)
                .layoutPriority(1)
            Text(parent)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .truncationMode(.head)
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
        HStack(spacing: 8) {
            Text("\(snapshot.branch) → \(snapshot.base)")
                .foregroundStyle(theme.branch)
                .lineLimit(1)
            Text(model.selectedPath ?? "")
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let fetchError = snapshot.fetchError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.needsYou)
                    .help("Couldn’t fetch \(snapshot.base), comparing local refs: \(fetchError)")
            }
            refreshButton
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    @ViewBuilder
    private var diff: some View {
        if let path = model.selectedPath, let contents = model.contents[path] {
            ReviewDiffPane(
                path: path,
                contents: contents,
                draft: $model.drafts[path],
                onComment: { line, endLine, text, snippet in
                    model.comments.append(ReviewComment(id: UUID().uuidString, path: path, line: line, endLine: endLine, text: text, snippet: snippet))
                },
                onSave: { model.save($0, to: path) }
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        store.reviewSessionID = nil
    }
}
