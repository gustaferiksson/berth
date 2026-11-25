import AppKit
import BerthCore
import SwiftUI

struct ReviewIssueCard: View {
    let issue: ClosingIssue
    @State private var preview: ItemPreview?
    @AppStorage(ProjectsModel.enabledKey) private var projectsEnabled = false
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = preview.flatMap { preview -> IssueState? in
            switch preview.state {
            case .open: .open
            case .closed, .completed: .completed
            case .notPlanned: .notPlanned
            case .draft, .merged: nil
            }
        } ?? issue.state
        let title = issue.title.isEmpty ? preview?.title : issue.title
        let tint = state.color(in: theme)
        let status = projectsEnabled ? store.projects.status(forRepository: issue.ref.repository, number: issue.ref.number)?.statusName : nil
        Button {
            if let url = issue.ref.url { openURL(url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label { Text(state == .completed ? "Closed" : state.title) } icon: { OcticonImage(Octicon(state)) }
                        .labelStyle(CompactLabel())
                        .fontWeight(.semibold)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.16), in: .rect(cornerRadius: 4))
                    Text(verbatim: "#\(issue.ref.number)").monospacedDigit()
                    Text(verbatim: issue.ref.repository).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("Issue")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let title {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                }
                if preview?.assignees.isEmpty == false || preview?.labels.isEmpty == false || status != nil {
                    HStack(spacing: 5) {
                        if let login = preview?.assignees.first {
                            Label(login, systemImage: "person")
                                .labelStyle(CompactLabel())
                        }
                        ForEach((preview?.labels ?? []).prefix(3), id: \.name) { label in
                            Text(label.name)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(theme.foreground.opacity(0.07), in: .rect(cornerRadius: 4))
                        }
                        Spacer(minLength: 0)
                        if let status { Text(status) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .modifier(ReviewPullRequestCardChrome(restingOpacity: 0.04))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = issue.ref.url {
                Button("Open on GitHub") { openURL(url) }
                Button("Copy Link") { copyToPasteboard(url.absoluteString) }
            }
        }
        .task(id: issue.ref) {
            preview = nil
            guard let url = issue.ref.url, let reference = ItemReference(url: url) else { return }

            let loaded = await ItemPreviewCache.shared.preview(for: reference)
            if !Task.isCancelled { preview = loaded }
        }
    }
}

struct ReviewPullRequestCard: View {
    let entry: ReviewPullRequest
    let model: ReviewModel
    let branch: String
    let base: String?
    let detail: PullRequestDetail?
    let showThreads: () -> Void
    @AppStorage(ProjectsModel.enabledKey) private var projectsEnabled = false
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let pullRequest = entry.pullRequest
        let selected = store.reviewModel === model && model.selectedDocument?.pullRequestLink == entry.id
        let decision = detail?.reviewDecision.flatMap(InboxPullRequest.ReviewDecision.init(rawValue:)) ?? pullRequest.reviewDecision
        let status = projectsEnabled ? store.projects.status(forRepository: entry.id.repository, number: entry.id.number)?.statusName : nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PullRequestStatePill(pullRequest: pullRequest, opensOnGitHub: false)
                Text(verbatim: "#\(entry.id.number)").monospacedDigit()
                Text(verbatim: entry.id.repository).lineLimit(1)
                Spacer(minLength: 0)
                ReviewPullRequestMenu {
                    ReviewPullRequestActions(entry: entry, model: model)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(pullRequest.title)
                .font(.headline)
                .lineLimit(2)
                .help(pullRequest.title)
            HStack(spacing: 5) {
                Text(verbatim: branch)
                    .truncationMode(.middle)
                if let base {
                    Text("→").fixedSize()
                    Text(verbatim: base)
                        .truncationMode(.middle)
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(base.map { "\(branch) → \($0)" } ?? branch)
            HStack(spacing: 8) {
                if let checks = detail?.checks {
                    ForEach([ItemChecks.Check.Outcome.passed, .failed, .running], id: \.self) { outcome in
                        let count = outcome == .passed ? checks.passed : outcome == .failed ? checks.failed : checks.running
                        if count > 0 {
                            let appearance = outcome.appearance(in: theme)
                            Label(count.formatted(), systemImage: appearance.icon)
                                .foregroundStyle(appearance.color)
                                .help("\(count) \(appearance.label.lowercased())")
                                .accessibilityLabel("\(count) \(appearance.label.lowercased())")
                        }
                    }
                }
                if let decision {
                    let appearance = decision.reviewAppearance(in: theme)
                    Image(systemName: appearance.icon)
                        .foregroundStyle(appearance.color)
                        .help(appearance.label)
                        .accessibilityLabel(appearance.label)
                }
                if let detail, !detail.threads.isEmpty {
                    Button(action: showThreads) {
                        Label(detail.unresolvedThreads.formatted(), systemImage: "bubble.left")
                    }
                    .buttonStyle(.plain)
                    .help("Show Review Threads")
                    .accessibilityLabel("\(detail.unresolvedThreads) unresolved review threads")
                }
                Spacer(minLength: 0)
                if let status { Text(status).lineLimit(1) }
            }
            .labelStyle(CompactLabel())
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .modifier(ReviewPullRequestCardChrome(isSelected: selected))
        .onTapGesture { Task { await model.openPullRequestDiff(entry) } }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Show Diff in Review") { Task { await model.openPullRequestDiff(entry) } }
        .contextMenu { ReviewPullRequestActions(entry: entry, model: model) }
    }
}

private struct ReviewPullRequestCardChrome: ViewModifier {
    var isSelected = false
    var restingOpacity = 0.07
    @State private var isHovering = false
    @Environment(\.ghosttyTheme) private var theme

    private var fillOpacity: Double {
        if isSelected { return 0.14 }
        return isHovering ? restingOpacity + 0.03 : restingOpacity
    }

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.foreground.opacity(fillOpacity), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

struct ReviewPullRequestEmpty: View {
    let changes: ReviewChanges
    let status: ReviewBranchStatus
    let sessionID: String
    let model: ReviewModel
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let upstream = if let upstream = status.upstream {
            if upstream.ahead > 0 {
                "\(upstream.ahead) not pushed" + (changes.isDefaultBranch ? " to \(upstream.name)" : "")
            } else if upstream.behind > 0 {
                "\(upstream.behind) behind \(upstream.name)"
            } else {
                "up to date with \(upstream.name)"
            }
        } else {
            "not pushed"
        }
        let upstreamSentence = upstream.prefix(1).uppercased() + upstream.dropFirst()
        VStack(alignment: .leading, spacing: 2) {
            if changes.isDefaultBranch {
                let summary = "\(upstreamSentence)."
                Text(summary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(summary)
            } else {
                HStack(spacing: 5) {
                    OcticonImage(.branch)
                    Text(changes.branch)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    ReviewPullRequestMenu {
                        Button("Create Pull Request…") { store.createPullRequest(sessionID: sessionID, model: model) }
                            .disabled(store.liveBySession[sessionID] == nil)
                        Button("Add Existing Pull Request…") { AppAction.showPullRequestInReview.perform(on: store) }
                    }
                }
                .foregroundStyle(theme.branch)
                if let base = changes.base {
                    let headBase = base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : base
                    let commits = status.ahead == 1 ? "commit" : "commits"
                    Text("No pull request yet. \(status.ahead) \(commits) ahead of \(headBase), \(upstream).")
                } else {
                    Text("No pull request yet. \(upstreamSentence).")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct ReviewCompactPullRequestRow: View {
    let entry: ReviewPullRequest
    let model: ReviewModel
    var isThisBranch = false
    var isExpanded = false
    var toggleExpansion: (() -> Void)?
    @State private var isHovering = UserDefaults.standard.bool(forKey: "snapshotHoverPullRequestRows")
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let pullRequest = entry.pullRequest
        let selected = store.reviewModel === model && model.selectedDocument?.pullRequestLink == entry.id
        let detail = isThisBranch ? model.pullRequestDetails[pullRequest.number] : nil
        let checks = detail?.checks?.state ?? pullRequest.checks
        let decision = detail?.reviewDecision.flatMap(InboxPullRequest.ReviewDecision.init(rawValue:)) ?? pullRequest.reviewDecision
        let decisionLabel = decision?.reviewAppearance(in: theme).label ?? "No review decision"
        let checksLabel = checks.map { "Checks \($0.rawValue)" } ?? "No checks"
        let idleFill = isThisBranch ? 0.025 : 0
        let rowHeight = toggleExpansion == nil ? 25.0 : 28.0
        let tint = if checks == .failed || decision == .changesRequested {
            theme.closed
        } else if checks == .running || decision == .reviewRequired {
            theme.needsYou
        } else if checks == .passed || decision == .approved {
            theme.working
        } else {
            theme.secondary
        }
        HStack(spacing: 5) {
            if let toggleExpansion {
                Button(action: toggleExpansion) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12, height: rowHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? "Hide Changed Files" : "Show Changed Files")
            }
            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    openURL(pullRequest.url)
                } else {
                    Task { await model.openPullRequestDiff(entry) }
                }
            } label: {
                HStack(spacing: 5) {
                    OcticonImage(Octicon(pullRequest.state))
                        .foregroundStyle(pullRequest.state.color(in: theme))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(pullRequest.state.rawValue)
                        .help(pullRequest.state.rawValue)
                    Text(verbatim: "#\(entry.id.number)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(pullRequest.title)
                        .font(.callout)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(pullRequest.title)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                            .help("\(checksLabel) · \(decisionLabel)")
                            .accessibilityLabel("\(checksLabel), \(decisionLabel)")
                        if pullRequest.commentCount > 0 {
                            Label(pullRequest.commentCount.formatted(), systemImage: "bubble.left")
                                .labelStyle(CompactLabel())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .help("\(pullRequest.commentCount) comments")
                        }
                    }
                    .frame(minWidth: 22, alignment: .trailing)
                    .fixedSize()
                    .opacity(isHovering ? 0 : 1)
                    .allowsHitTesting(!isHovering)
                    .accessibilityHidden(isHovering)
                }
                .frame(minHeight: rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(isThisBranch ? "This branch" : "")
            .overlay(alignment: .trailing) {
                if isHovering {
                    ReviewPullRequestMenu {
                        ReviewPullRequestActions(entry: entry, model: model)
                    }
                }
            }
        }
        .font(.caption)
        .padding(.leading, 5)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .listRowBackground(RowFill(opacity: selected ? 0.1 : isHovering ? 0.05 : idleFill, color: theme.foreground, cornerRadius: 4))
        .contextMenu { ReviewPullRequestActions(entry: entry, model: model) }
    }
}

struct ReviewPullRequestStackRows: View {
    let branch: ReviewPullRequest
    let stack: ReviewPullRequestStack
    let model: ReviewModel
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if let parent = stack.parent {
            row(parent, depth: 0, connectsAbove: false, hasSiblingBelow: false, hasChildren: true)
        }
        row(branch.pullRequest, depth: 1, connectsAbove: stack.parent != nil, hasSiblingBelow: false, hasChildren: !stack.children.isEmpty)
        ForEach(stack.children, id: \.number) { child in
            row(child, depth: 2, connectsAbove: true, hasSiblingBelow: child.number != stack.children.last?.number, hasChildren: false)
        }
    }

    private func row(_ pullRequest: PullRequest, depth: Int, connectsAbove: Bool, hasSiblingBelow: Bool, hasChildren: Bool) -> some View {
        let indentation = Double(depth) * 12
        let entry = ReviewPullRequest(pullRequest: pullRequest, repository: branch.id.repository, root: branch.location.root)
        return ReviewCompactPullRequestRow(entry: entry, model: model, isThisBranch: entry.id == branch.id)
            .reviewRow(leading: indentation)
            .overlay(alignment: .leading) {
                Canvas { context, size in
                    var path = Path()
                    let middle = size.height / 2
                    if connectsAbove {
                        let x = indentation - 7
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: hasSiblingBelow ? size.height : middle))
                        path.move(to: CGPoint(x: x, y: middle))
                        path.addLine(to: CGPoint(x: indentation, y: middle))
                    }
                    if hasChildren {
                        let x = indentation + 5
                        path.move(to: CGPoint(x: x, y: middle + 8))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(path, with: .color(theme.foreground.opacity(0.15)), lineWidth: 1)
                }
                .frame(width: indentation + 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct ReviewPullRequestMenu<Actions: View>: View {
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Menu(content: actions) {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 22, height: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Pull Request Actions")
    }
}

private struct ReviewPullRequestActions: View {
    let entry: ReviewPullRequest
    let model: ReviewModel
    @AppStorage(ProjectsModel.enabledKey) private var projectsEnabled = false
    @Environment(Store.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        let pullRequest = entry.pullRequest
        Button("Show Details") { model.openPullRequestDetails(entry) }
        Button("Open on GitHub") { openURL(pullRequest.url) }
        if pullRequest.state == .open || pullRequest.state == .draft {
            StewardPullRequestButton(link: entry.id, url: pullRequest.url)
        }
        Button("Show Diff in Review") { Task { await model.openPullRequestDiff(entry) } }
        if projectsEnabled,
           let item = store.projects.selectedBoards.lazy.filter({ $0.statusFieldID != nil && !$0.statusOptions.isEmpty })
               .flatMap(\.items).first(where: { $0.linkKey == "\(entry.id.repository)#\(entry.id.number)" }) {
            ProjectMoveToStatusMenu(item: item)
        }
        Button("Copy Link") { copyToPasteboard(pullRequest.url.absoluteString) }
    }
}

extension InboxPullRequest.ReviewDecision {
    func reviewAppearance(in theme: GhosttyTheme) -> (icon: String, label: String, color: Color) {
        switch self {
        case .approved: ("checkmark.seal.fill", "Approved", theme.working)
        case .changesRequested: ("exclamationmark.circle.fill", "Changes requested", theme.closed)
        case .reviewRequired: ("eye", "Review required", theme.needsYou)
        }
    }
}
