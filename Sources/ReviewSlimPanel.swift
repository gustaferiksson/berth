import BerthCore
import SwiftUI

enum ReviewSlimScope: String {
    case changes
    case commits
    case files
}

extension ReviewFileList {
    func slimPanel(_ changes: ReviewChanges?) -> some View {
        let shown = changes.flatMap { shownPullRequest(root: nil, branch: $0.branch) }
        let pullRequest = shown?.pullRequest
        let detail = pullRequest.flatMap { model.pullRequestDetails[$0.number] }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let changes {
                        HStack(spacing: 4) {
                            Text(changes.branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(changes.branch)
                            if !changes.isDefaultBranch, let base = changes.base {
                                baseMenu(base, candidates: changes.bases)
                            }
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.branch)
                    }
                    Spacer(minLength: 0)
                    if let changes { panelWarnings(changes) }
                    treeToggle(changes)
                    refreshButton
                }
                .font(.callout)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(theme.secondary)
                if let changes {
                    slimSummary(changes, pullRequest: pullRequest, detail: detail, knowsPullRequest: shown != nil)
                    if shown != nil, pullRequest == nil, !changes.isDefaultBranch, changes.base != nil, (model.status?.ahead ?? 0) > 0 {
                        slimCreatePullRequest(live: store.liveBySession[sessionID] != nil)
                    }
                    if let pullRequest {
                        Text(pullRequest.title)
                            .font(.callout)
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(pullRequest.title)
                    }
                    if let status = model.status {
                        slimBranchStatus(status, changes: changes)
                    }
                }
            }
            .padding(.horizontal, ReviewInset.content)
            .padding(.top, 12)
            .padding(.bottom, 10)
            movedFolderNotice
            VStack(spacing: 0) {
                Picker("Review scope", selection: changes == nil ? .constant(.changes) : slimScope) {
                    (detail?.changedFiles.map { Text("Changes \($0)") } ?? Text("Changes"))
                        .tag(ReviewSlimScope.changes)
                    (detail?.commits.map { Text("Commits \($0)") } ?? Text("Commits"))
                        .tag(ReviewSlimScope.commits)
                    Text("Files").tag(ReviewSlimScope.files)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(changes == nil)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .padding(.horizontal, ReviewInset.content)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Rectangle()
                .fill(theme.foreground.opacity(0.1))
                .frame(height: 1)
                .accessibilityHidden(true)
            if let changes {
                switch slimScope.wrappedValue {
                case .changes: changesList(changes)
                case .commits: slimCommits(changes)
                case .files: repositoryFilesList(changes)
                }
            } else {
                changesList(nil)
            }
            commentsBar
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private func slimSummary(_ changes: ReviewChanges, pullRequest: PullRequest?, detail: PullRequestDetail?, knowsPullRequest: Bool) -> some View {
        HStack(spacing: 6) {
            slimPullRequestFacts(pullRequest, detail: detail, knowsPullRequest: knowsPullRequest)
            Spacer(minLength: 0)
            slimBranchTotal(changes)
                .layoutPriority(1)
        }
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private func slimPullRequestFacts(_ pullRequest: PullRequest?, detail: PullRequestDetail?, knowsPullRequest: Bool) -> some View {
        if let pullRequest {
            PullRequestStatePill(pullRequest: pullRequest, isSlim: true)
            ReviewSlimPullRequestLink(pullRequest: pullRequest)
            if let checks = detail?.checks {
                let icon: (String, Color) = switch checks.state {
                case .passed: ("checkmark.circle.fill", theme.working)
                case .failed: ("xmark.circle.fill", theme.closed)
                case .running: ("clock", theme.needsYou)
                }
                let description = "Checks · \(checks.passed) passed, \(checks.failed) failed, \(checks.running) running"
                Label("\(checks.passed)/\(checks.passed + checks.failed + checks.running)", systemImage: icon.0)
                    .labelStyle(CompactLabel())
                    .monospacedDigit()
                    .foregroundStyle(icon.1)
                    .help(description)
                    .accessibilityLabel(description)
            }
            if let decision = detail?.reviewDecision.flatMap(InboxPullRequest.ReviewDecision.init(rawValue:)) ?? pullRequest.reviewDecision {
                let tag: (String, String, Color) = switch decision {
                case .approved: ("Approved", "checkmark.seal", theme.working)
                case .changesRequested: ("Changes requested", "exclamationmark.bubble", theme.closed)
                case .reviewRequired: ("Review required", "person.crop.circle.badge.questionmark", theme.needsYou)
                }
                Image(systemName: tag.1)
                    .foregroundStyle(tag.2)
                    .help(tag.0)
                    .accessibilityLabel(tag.0)
            }
            if let detail {
                let count = detail.unresolvedThreads
                Button { showSlimThreadSection(detail) } label: {
                    Label("\(count)", systemImage: "bubble.left")
                        .labelStyle(CompactLabel())
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.foreground)
                .disabled(detail.threads.isEmpty)
                .help(detail.threads.isEmpty ? "No review threads" : "Show Review Threads")
                .accessibilityLabel("\(count) unresolved review threads")
            }
        } else if knowsPullRequest {
            Text("No pull request")
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.foreground.opacity(0.08), in: .rect(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func slimBranchTotal(_ changes: ReviewChanges) -> some View {
        if let total = changes.total {
            HStack(spacing: 4) {
                Text("+\(total.additions)").foregroundStyle(total.additions == 0 ? theme.secondary : theme.working)
                Text("−\(total.deletions)").foregroundStyle(total.deletions == 0 ? theme.secondary : theme.closed)
            }
            .monospacedDigit()
            .fixedSize()
            .help("Changes against \(changes.base ?? ""), uncommitted included")
            .accessibilityLabel("Branch total, \(total.additions) additions and \(total.deletions) deletions")
        }
    }

    private func slimCreatePullRequest(live: Bool) -> some View {
        Button("Create Pull Request…", action: createPullRequest)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!live)
            .help(live ? "Paste a prompt asking Claude to push this branch and open a pull request" : "Claude isn’t running in this tab")
    }

    @ViewBuilder
    private func slimBranchStatus(_ status: ReviewBranchStatus, changes: ReviewChanges) -> some View {
        let base = status.ahead > 0 || status.behind > 0 ? "↑\(status.ahead) ↓\(status.behind)" : nil
        let push = if let upstream = status.upstream {
            [
                upstream.ahead > 0 ? "\(upstream.ahead) not pushed" : nil,
                upstream.behind > 0 ? "\(upstream.behind) behind \(upstream.name)" : nil,
            ].compactMap(\.self).joined(separator: " · ")
        } else if status.ahead > 0 || !status.commits.isEmpty {
            "No upstream"
        } else {
            ""
        }
        let caption = [base, push.isEmpty ? nil : push].compactMap(\.self).joined(separator: " · ")
        if !caption.isEmpty {
            Text(caption)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .help("↑ Ahead and ↓ behind \(changes.base ?? "the base") · \(caption)")
        }
    }

    @ViewBuilder
    func slimChangeSections(_ changes: ReviewChanges?) -> some View {
        if let changes {
            threadSection(in: model, root: nil)
            let both = !changes.uncommitted.isEmpty && !changes.committed.isEmpty
            if !changes.uncommitted.isEmpty {
                slimChangeSection("Uncommitted", id: "uncommitted", files: changes.uncommitted, compare: .uncommitted, changes: changes, collapsible: both)
            }
            if !changes.committed.isEmpty {
                slimChangeSection("Committed", id: "committed", files: changes.committed, compare: .committed, changes: changes, collapsible: both)
            }
            if changes.uncommitted.isEmpty, changes.committed.isEmpty {
                Text(changes.isDefaultBranch || changes.base == nil ? "No uncommitted changes on \(changes.branch)" : "No changes, \(changes.branch) matches \(changes.base ?? "")")
                    .font(.callout)
                    .foregroundStyle(theme.secondary)
                    .reviewRow(top: 6, bottom: 6)
            }
            let shown = shownPullRequest(root: nil, branch: changes.branch)?.pullRequest?.number
            let other = store.pullRequests(inRoot: nil, of: sessionID, branch: changes.branch).filter { $0.number != shown }
            if !other.isEmpty {
                let expanded = expansion(of: "otherPullRequests", defaultExpanded: false)
                ReviewSlimSectionHeader(title: "Other pull requests", count: other.count, expansion: expanded)
                if expanded.wrappedValue {
                    ReviewOtherPullRequests(pullRequests: other, showsHeading: false)
                }
            }
        }
    }

    @ViewBuilder
    private func slimChangeSection(_ title: String, id: String, files: [ReviewFile], compare: ReviewCompare, changes: ReviewChanges, collapsible: Bool) -> some View {
        let expanded = collapsible ? expansion(of: id) : nil
        let additions = files.compactMap(\.additions).reduce(0, +)
        let deletions = files.compactMap(\.deletions).reduce(0, +)
        ReviewSlimSectionHeader(title: title, count: files.count, expansion: expanded, totals: (additions, deletions))
        if expanded?.wrappedValue ?? true {
            changeRows(files, compare: compare, changes: changes, in: model, root: nil)
        }
    }

    private func slimCommits(_ changes: ReviewChanges) -> some View {
        ReviewGraphView(model: model, changes: changes, showsHistory: slimHistory.wrappedValue) {
            if let commits = model.status?.commits {
                if commits.isEmpty {
                    Text("No branch commits")
                        .font(.callout)
                        .foregroundStyle(theme.secondary)
                        .reviewRow(top: 6, bottom: 6)
                }
                ForEach(commits, id: \.sha) { commit in
                    ReviewBranchCommitRow(commit: commit, isSlim: true)
                        .font(.callout)
                        .lineLimit(1)
                        .reviewRow()
                }
            }
            ReviewSlimSectionHeader(title: "History", expansion: slimHistory)
        }
    }

    var slimCommentsFooter: some View {
        let sendLabel = "Send \(commentCount) \(commentCount == 1 ? "Comment" : "Comments")"
        return HStack(spacing: 6) {
            Button {
                model.showsCommentList.toggle()
            } label: {
                Label("^[\(commentCount) comment](inflect: true)", systemImage: model.showsCommentList ? "chevron.down" : "chevron.up")
                    .labelStyle(CompactLabel())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondary)
            .help(model.showsCommentList ? "Hide the comment list" : "Show the comment list")
            Spacer(minLength: 0)
            Button("Send", action: sendComments)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(sendLabel)
                .accessibilityLabel(sendLabel)
        }
        .font(.caption)
        .padding(.leading, ReviewInset.content)
        .padding(.trailing, ReviewInset.fill)
        .frame(height: 36)
    }
}

struct ReviewSlimSectionHeader: View {
    let title: String
    var count: Int?
    var expansion: Binding<Bool>?
    var totals: (additions: Int, deletions: Int)?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if let expansion {
                Button {
                    expansion.wrappedValue.toggle()
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .accessibilityValue(expansion.wrappedValue ? "Expanded" : "Collapsed")
            } else {
                label
            }
        }
        .reviewRow(top: 6, bottom: 3)
    }

    private var label: some View {
        HStack(spacing: 6) {
            if let expansion {
                Image(systemName: expansion.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
            }
            if let totals {
                ReviewSlimLineCounts(additions: totals.additions, deletions: totals.deletions)
            }
        }
        .foregroundStyle(theme.secondary)
        .lineLimit(1)
        .contentShape(.rect)
    }
}

struct ReviewSlimChangeColumns<Counts: View>: View {
    let file: ReviewFile
    let showsFolder: Bool
    @ViewBuilder let counts: Counts
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let path = file.path as NSString
        let status = switch file.status {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
        HStack(spacing: 6) {
            Text(file.status.rawValue)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(file.status.color(in: theme))
                .frame(width: 12)
                .accessibilityLabel(status)
            Text(path.lastPathComponent)
                .font(.callout)
                .truncationMode(.middle)
            if showsFolder, !path.deletingLastPathComponent.isEmpty {
                Text(path.deletingLastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(theme.secondary)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            counts
        }
        .lineLimit(1)
    }
}

struct ReviewSlimLineCounts: View {
    let additions: Int?
    let deletions: Int?
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text(additions.map { "+\($0)" } ?? "")
                .foregroundStyle(additions == 0 ? theme.secondary : theme.working)
                .frame(width: 32, alignment: .trailing)
                .accessibilityLabel(additions.map { "\($0) additions" } ?? "")
            Text(deletions.map { "−\($0)" } ?? "")
                .foregroundStyle(deletions == 0 ? theme.secondary : theme.closed)
                .frame(width: 32, alignment: .trailing)
                .accessibilityLabel(deletions.map { "\($0) deletions" } ?? "")
        }
        .font(.caption2)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }
}

private struct ReviewSlimPullRequestLink: View {
    let pullRequest: PullRequest
    @Environment(\.openURL) private var openURL
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Button { openURL(pullRequest.url) } label: {
            Text(verbatim: "#\(pullRequest.number)")
                .monospacedDigit()
        }
        .buttonStyle(.link)
        .foregroundStyle(theme.branch)
        .pointerStyle(.link)
        .help("Open pull request #\(String(pullRequest.number)) on GitHub")
        .contextMenu {
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.url.absoluteString, forType: .string)
            }
            Button("Copy Number", systemImage: "number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("#\(pullRequest.number)", forType: .string)
            }
        }
    }
}

struct ReviewBranchCommitRow: View {
    let commit: ReviewCommit
    var isSlim = false
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
                .layoutPriority(isSlim ? -1 : 0)
            Spacer(minLength: 4)
            Text(age(since: commit.date))
                .font(.caption)
                .foregroundStyle(theme.secondary)
        }
        .frame(height: 22)
        .help(commit.subject)
    }
}
