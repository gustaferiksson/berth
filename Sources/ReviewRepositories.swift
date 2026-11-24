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

nonisolated struct ReviewPullRequestFiles: Sendable {
    let compare: ReviewCompare
    let files: [ReviewFile]
}

extension ReviewModel {
    func openPullRequestFile(_ file: ReviewFile, of entry: ReviewPullRequest, compare: ReviewCompare) {
        guard file.status != .deleted, case let .range(_, head) = compare else { return }

        let root = entry.location.root
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
    var showsRepository = false
    @Environment(\.openURL) private var openURL
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ForEach(entries) { entry in
            let link = entry.id
            let pullRequest = entry.pullRequest
            let isExpanded = model.expandedPullRequests.contains(link)
            Button {
                if isExpanded {
                    model.expandedPullRequests.remove(link)
                } else {
                    Task { await model.expandPullRequest(entry) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 10)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pullRequest.title)
                        if showsRepository {
                            Text(link.repository)
                                .font(.caption2)
                                .foregroundStyle(theme.secondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PullRequestTag(pullRequest: pullRequest, opensOnGitHub: false)
                        .fixedSize()
                }
                .padding(.vertical, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(pullRequest.title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .contextMenu {
                Button("Open on GitHub") { openURL(pullRequest.url) }
                if [.open, .draft].contains(pullRequest.state) {
                    StewardPullRequestButton(link: link, url: pullRequest.url)
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
                    ForEach(loaded.files, id: \.path) { file in
                        let document = ReviewDocument(path: file.path, compare: loaded.compare, root: entry.location.root, pullRequestLink: link)
                        let open = { model.openPullRequestFile(file, of: entry, compare: loaded.compare) }
                        let local = model.changes?.root == entry.location.root ? (entry.location.root as NSString).appendingPathComponent(file.path) : nil
                        ReviewHistoricalFileButton(file: file, document: document, model: model, openFile: file.status == .deleted ? nil : open)
                            .reviewRow(leading: ReviewInset.tree)
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
