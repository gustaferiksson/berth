import BerthCore
import Foundation
import SwiftUI

struct ReviewTaskHeader: View {
    let title: String
    let issue: IssueRef?
    let members: [SessionSummary]
    let currentID: String
    let pullRequestCount: Int
    let repositoryCount: Int
    let showsRepositories: Bool
    @Binding var isExpanded: Bool
    let activate: (String) -> Void
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let issue {
                IssueStatePill(issue: issue)
            }
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .help(title)
            if let issue {
                Text(verbatim: issue.repository)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Text("^[\(members.count) session](inflect: true) · \(pullRequestCount) \(pullRequestCount == 1 ? "PR" : "PRs") · ^[\(repositoryCount) repo](inflect: true)")
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .accessibilityLabel(isExpanded ? "Hide Sessions" : "Show Sessions")
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(members.prefix(6)) { member in
                    let activity = store.liveBySession[member.id]?.activity
                    Button { activate(member.id) } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(activity == .working ? theme.working : activity.map { if case .needsInput = $0 { true } else { false } } == true ? theme.needsYou : Color.secondary.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(member.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 4)
                            if showsRepositories {
                                Text(URL(filePath: member.checkout).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                    .layoutPriority(-1)
                            }
                        }
                        .font(.callout)
                        .fontWeight(member.id == currentID ? .semibold : .regular)
                        .frame(height: 22)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(member.title)
                }
                if members.count > 6 {
                    Text("\(members.count - 6) more")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(.horizontal, ReviewInset.content - ReviewInset.fill)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReviewRepoRow: Identifiable {
    let id: String
    let name: String
    let branch: String?
    let base: String?
    let pullRequest: PullRequest?
}

struct ReviewRepoRows: View {
    let rows: [ReviewRepoRow]
    @Binding var selection: String
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Button { selection = row.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: row.id == "all" ? "square.stack.3d.up" : "folder")
                                .foregroundStyle(theme.secondary)
                                .accessibilityHidden(true)
                            Text(row.name)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            if let branch = row.branch {
                                Text(row.base.map { "\(branch) → \($0)" } ?? branch)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(theme.branch)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .layoutPriority(-1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if let pullRequest = row.pullRequest {
                        PullRequestTag(pullRequest: pullRequest)
                            .fixedSize()
                    }
                }
                .font(.callout)
                .padding(.horizontal, 4)
                .frame(height: 28)
                .background(theme.foreground.opacity(row.id == selection ? 0.09 : 0), in: .rect(cornerRadius: 8))
                .help(row.id == "all" ? "Show every repository" : "Show \(row.name)")
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

struct ReviewPullRequestFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

nonisolated struct ReviewPullRequestLocation: Hashable, Sendable {
    let link: PullRequestLink
    let root: String
}

struct ReviewPullRequest: Identifiable {
    let location: ReviewPullRequestLocation
    let pullRequest: PullRequest

    var id: PullRequestLink { location.link }
}

extension ReviewPullRequest {
    init(pullRequest: PullRequest, repository: String, root: String) {
        self.init(location: ReviewPullRequestLocation(link: PullRequestLink(repository: repository.lowercased(), number: pullRequest.number), root: root), pullRequest: pullRequest)
    }
}

nonisolated struct ReviewPullRequestFiles: Sendable {
    let compare: ReviewCompare
    let files: [ReviewFile]
}

extension ReviewModel {
    func openPullRequestFile(_ file: ReviewFile, of entry: ReviewPullRequest, compare: ReviewCompare) async {
        guard file.status != .deleted, case let .range(_, head) = compare else { return }

        let root = entry.location.root
        if let branch = entry.pullRequest.headRefName,
           let worktree = await PullRequestCheckout.checkedOutWorktree(branch: branch, head: head, in: root),
           await Store.shared.openWorktreeFile(file.path, in: worktree, origin: ReviewPullRequestOrigin(link: entry.id, behind: worktree.behind, ahead: worktree.ahead), from: self) {
            return
        }
        if changes?.root == root, FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(file.path)) {
            open(workingDocument(file.path))
            return
        }

        let document = ReviewDocument(path: file.path, compare: .range(base: head, head: head), root: root, pullRequestLink: entry.id)
        rangeFiles[document] = ReviewFile(path: file.path, oldPath: nil, status: .modified, additions: nil, deletions: nil)
        open(document)
    }
}

struct ReviewOtherPullRequests: View {
    let entries: [ReviewPullRequest]
    let model: ReviewModel
    let changesAsTree: Bool
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ForEach(entries) { entry in
            let link = entry.id
            let isExpanded = model.expandedPullRequests.contains(link)
            ReviewCompactPullRequestRow(entry: entry, model: model, isExpanded: isExpanded) {
                if isExpanded {
                    model.expandedPullRequests.remove(link)
                } else {
                    Task { await model.expandPullRequest(entry) }
                }
            }
            .reviewRow()
            if isExpanded {
                if model.loadingPullRequests[entry.location] != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading Changed Files")
                        .frame(height: 24)
                        .reviewRow(leading: ReviewInset.tree)
                } else if let loaded = model.pullRequestFiles[entry.location], !loaded.files.isEmpty {
                    if changesAsTree {
                        let files = Dictionary(loaded.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                        ForEach(ReviewFileTree.compactNodes(loaded.files.map(\.path))) { node in
                            ReviewPullRequestFileNode(node: node, files: files, entry: entry, compare: loaded.compare, model: model)
                        }
                    } else {
                        ForEach(loaded.files, id: \.path) { file in
                            ReviewPullRequestFileRow(file: file, entry: entry, compare: loaded.compare, model: model)
                        }
                    }
                } else {
                    Text("No changed files")
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .reviewRow(top: 4, bottom: 4, leading: ReviewInset.tree)
                }
            }
        }
    }
}

private struct ReviewPullRequestFileNode: View {
    let node: ReviewFileTree
    let files: [String: ReviewFile]
    let entry: ReviewPullRequest
    let compare: ReviewCompare
    let model: ReviewModel
    var depth = 1
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if let children = node.children {
            let folder = ReviewDocument(path: node.path, compare: compare, root: entry.location.root, pullRequestLink: entry.id)
            let isExpanded = !model.collapsedChangeFolders.contains(folder)
            ReviewFolderRow(isExpanded: isExpanded, depth: depth, verticalPadding: 0, minHeight: 28) {
                if isExpanded { model.collapsedChangeFolders.insert(folder) } else { model.collapsedChangeFolders.remove(folder) }
            } label: {
                Label {
                    Text(node.name)
                        .monospaced()
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fontWeight(.regular)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(theme.secondary)
                }
                .font(.subheadline)
                .help(node.path)
            }
            if isExpanded {
                ForEach(children) { Self(node: $0, files: files, entry: entry, compare: compare, model: model, depth: depth + 1) }
            }
        } else if let file = files[node.path] {
            ReviewPullRequestFileRow(file: file, entry: entry, compare: compare, model: model, depth: depth + 1)
        }
    }
}

private struct ReviewPullRequestFileRow: View {
    let file: ReviewFile
    let entry: ReviewPullRequest
    let compare: ReviewCompare
    let model: ReviewModel
    var depth = 1

    var body: some View {
        let root = entry.location.root
        let document = ReviewDocument(path: file.path, compare: compare, root: root, pullRequestLink: entry.id)
        let open: () -> Void = { Task { await model.openPullRequestFile(file, of: entry, compare: compare) } }
        let local = model.changes?.root == root ? (root as NSString).appendingPathComponent(file.path) : nil
        ReviewHistoricalFileButton(file: file, document: document, model: model, openFile: file.status == .deleted ? nil : open, minHeight: 28, trailingPadding: 0)
            .reviewRow(leading: Double(depth) * ReviewInset.tree)
            .id(document)
            .contextMenu {
                if file.status != .deleted {
                    Button("Open File", systemImage: "doc", action: open)
                }
                if let local, FileManager.default.fileExists(atPath: local) {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: local)]) }
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(local ?? file.path, forType: .string)
                }
            }
    }
}

struct ReviewFolderRow<Label: View>: View {
    let isExpanded: Bool
    let depth: Int
    var verticalPadding = 6.5
    var minHeight: CGFloat?
    let toggle: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 10)
                    .accessibilityHidden(true)
                label()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .reviewRow(leading: Double(depth) * ReviewInset.tree)
    }
}

struct ReviewRepositoryHeader<Accessory: View>: View {
    let title: String
    let help: String
    let isExpanded: Binding<Bool>
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        SidebarSectionHeader(title: title, help: help, count: nil, isExpanded: isExpanded, accessory: nil as EmptyView?, replacementTitle: titleButton)
    }

    private var titleButton: some View {
        Button { isExpanded.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                accessory()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityValue(isExpanded.wrappedValue ? "expanded" : "collapsed")
    }
}

struct ReviewRepositoryAccessory: View {
    let branch: String?
    let base: String?
    let pullRequests: [PullRequest]
    let hiding: Int?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if let branch {
                Text(base.map { "\(branch) → \($0)" } ?? branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .transaction { $0.animation = nil }
            }
            ForEach(pullRequests, id: \.number) { pullRequest in
                PullRequestTag(pullRequest: pullRequest)
                    .fixedSize()
                    .opacity(pullRequest.number == hiding ? 0 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hiding)
    }
}

struct ReviewSubheading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .fixedSize()
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.secondary)
        .frame(height: 22)
        .reviewRow(top: 2)
    }
}

enum ReviewInset {
    static let fill = 8.0
    static let content = 16.0
    static let tree = 18.0
}

struct ReviewFileStats: View {
    let file: ReviewFile
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let additions = file.additions.flatMap { $0 > 0 ? $0 : nil }
        let deletions = file.deletions.flatMap { $0 > 0 ? $0 : nil }
        var text = AttributedString()
        if let additions {
            var part = AttributedString("+\(additions)")
            part.foregroundColor = theme.working
            text += part
        }
        if additions != nil, deletions != nil { text += AttributedString(" ") }
        if let deletions {
            var part = AttributedString("−\(deletions)")
            part.foregroundColor = theme.closed
            text += part
        }
        return Text(text)
            .monospacedDigit()
            .fixedSize()
            .accessibilityLabel([additions.map { "\($0) additions" }, deletions.map { "\($0) deletions" }].compactMap(\.self).joined(separator: ", "))
    }
}

extension View {
    func reviewRow(top: Double = 0, bottom: Double = 0, leading: Double = 0) -> some View {
        padding(.leading, leading)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
    }
}

struct ReviewBranchCommitRow: View {
    let commit: ReviewCommit
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
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
}

struct ReviewBranchCard: View {
    let changes: ReviewChanges
    let status: ReviewBranchStatus
    let pullRequest: PullRequest??
    let repository: String?
    let detail: PullRequestDetail?
    let isClaudeLive: Bool
    let createPullRequest: (() -> Void)?
    let showThreads: () -> Void
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let found = pullRequest ?? nil
        let decision = detail?.reviewDecision.flatMap(InboxPullRequest.ReviewDecision.init(rawValue:)) ?? found?.reviewDecision
        VStack(alignment: .leading, spacing: 10) {
            if found == nil, changes.isDefaultBranch || changes.base == nil {
                Text(changes.uncommitted.isEmpty ? "No uncommitted changes on \(changes.branch)" : "Uncommitted changes on \(changes.branch)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pushState
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                headline(found)
                Text(verbatim: "\(found?.headRefName ?? changes.branch) → \(found?.baseRefName ?? changes.base ?? "")")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if found != nil {
                    if detail != nil || decision != nil {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { reviewStatus(decision) }
                            VStack(alignment: .leading, spacing: 4) { reviewStatus(decision) }
                        }
                        .font(.caption)
                    }
                    checksRow
                } else {
                    ViewThatFits(in: .horizontal) {
                        facts
                        VStack(alignment: .leading, spacing: 2) { facts }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                }
            }
            actions(found)
        }
        .lineLimit(1)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .geometryGroup()
    }

    private func headline(_ found: PullRequest?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if pullRequest != nil {
                HStack(spacing: 8) {
                    if let found {
                        PullRequestStatePill(pullRequest: found)
                        Text(verbatim: "#\(found.number)")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary)
                    } else {
                        Label("No pull request", systemImage: "arrow.triangle.branch")
                            .labelStyle(CompactLabel())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.16), in: .rect(cornerRadius: 4))
                    }
                    Spacer(minLength: 0)
                    if let found { moreMenu(found) }
                }
            }
            if let found {
                Text(found.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .help(found.title)
                    .contextMenu { stewardAction(found) }
            } else {
                Text(status.ahead == 0 ? "No commits yet" : "\(status.ahead) \(status.ahead == 1 ? "commit" : "commits")")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private var facts: some View {
        if status.behind > 0 {
            Label("\(status.behind) behind", systemImage: "arrow.down")
                .help("\(status.behind) behind \(changes.base ?? "")")
        }
        if let total = changes.total {
            Text("+\(total.additions) −\(total.deletions)")
                .monospacedDigit()
                .help("Changes against \(changes.base ?? ""), uncommitted included")
        }
        if status.ahead > 0 {
            pushState
        }
    }

    @ViewBuilder
    private func reviewStatus(_ decision: InboxPullRequest.ReviewDecision?) -> some View {
        if let decision {
            let tag: (String, Color) = switch decision {
            case .approved: ("Approved", theme.working)
            case .changesRequested: ("Changes requested", theme.closed)
            case .reviewRequired: ("Review required", theme.needsYou)
            }
            Text(tag.0)
                .fontWeight(.semibold)
                .foregroundStyle(tag.1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tag.1.opacity(0.16), in: .rect(cornerRadius: 4))
        }
        if let detail {
            let open = detail.unresolvedThreads
            Button(action: showThreads) {
                Label(open == 0 ? "All resolved" : "\(open) open", systemImage: open == 0 ? "checkmark" : "bubble.left")
                    .labelStyle(CompactLabel())
                    .monospacedDigit()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(open == 0 ? theme.working : theme.foreground)
            .disabled(detail.threads.isEmpty)
            .help(detail.threads.isEmpty ? "No review threads" : "Show Review Threads")
        }
    }

    @ViewBuilder private var checksRow: some View {
        if detail?.checks != nil || detail?.changedFiles != nil || detail?.commits != nil || changes.total != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { pullRequestFacts }
                VStack(alignment: .leading, spacing: 4) { pullRequestFacts }
            }
        }
    }

    @ViewBuilder private var pullRequestFacts: some View {
        if let checks = detail?.checks {
            HStack(spacing: 8) {
                if checks.passed > 0 {
                    Label("\(checks.passed)", systemImage: "checkmark.circle.fill").foregroundStyle(theme.working)
                }
                if checks.failed > 0 {
                    Label("\(checks.failed)", systemImage: "xmark.circle.fill").foregroundStyle(theme.closed)
                }
                if checks.running > 0 {
                    Label("\(checks.running)", systemImage: "clock.fill").foregroundStyle(theme.needsYou)
                }
            }
            .labelStyle(CompactLabel())
            .font(.callout.weight(.medium))
            .fixedSize()
            .help("Checks · \(checks.passed) passed, \(checks.failed) failed, \(checks.running) running")
        }
        HStack(spacing: 6) {
            if let files = detail?.changedFiles { Text("\(files) \(files == 1 ? "file" : "files")") }
            if let commits = detail?.commits { Text("\(commits) \(commits == 1 ? "commit" : "commits")") }
            if let total = changes.total {
                Text("+\(total.additions) −\(total.deletions)")
                    .help("Changes against \(changes.base ?? ""), uncommitted included")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(Color.secondary)
    }

    @ViewBuilder
    private func actions(_ found: PullRequest?) -> some View {
        if let createPullRequest, pullRequest != nil, found == nil, !changes.isDefaultBranch, changes.base != nil, status.ahead > 0 {
            Button(action: createPullRequest) {
                Text("Create Pull Request…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!isClaudeLive)
            .help(isClaudeLive ? "Paste a prompt asking Claude to push this branch and open a pull request" : "Claude isn’t running in this tab")
        }
    }

    @ViewBuilder
    private func stewardAction(_ found: PullRequest) -> some View {
        if let repository, [.open, .draft].contains(found.state) {
            StewardPullRequestButton(link: PullRequestLink(repository: repository, number: found.number), url: found.url)
        }
    }

    private func moreMenu(_ found: PullRequest) -> some View {
        Menu {
            Button("Open on GitHub", systemImage: "arrow.up.right.square") { openURL(found.url) }
            stewardAction(found)
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(found.url.absoluteString, forType: .string)
            }
            Button("Copy Number", systemImage: "number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("#\(found.number)", forType: .string)
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel("More")
        }
        .menuIndicator(.hidden)
        .foregroundStyle(theme.secondary)
        .frame(width: 20, alignment: .trailing)
        .padding(.trailing, 2)
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
                Label(changes.isDefaultBranch || changes.base == nil ? "No upstream" : "Not pushed", systemImage: "arrow.up")
                    .foregroundStyle(theme.needsYou)
                    .help("\(changes.branch) has no upstream branch")
            }
        }
        .labelStyle(CompactLabel())
    }
}
