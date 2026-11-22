import BerthCore
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
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
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
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background(theme.foreground.opacity(row.id == selection ? 0.09 : 0), in: .rect(cornerRadius: 8))
                .help(row.id == "all" ? "Show every repository" : "Show \(row.name)")
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

struct ReviewOtherPullRequests: View {
    let pullRequests: [PullRequest]
    let insets: EdgeInsets
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !pullRequests.isEmpty {
            Text("Other pull requests")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .listRowInsets(insets)
        }
        ForEach(pullRequests, id: \.number) { pullRequest in
            HStack(spacing: 8) {
                Button { openURL(pullRequest.url) } label: {
                    Text(pullRequest.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(pullRequest.title)
                PullRequestTag(pullRequest: pullRequest)
                    .fixedSize()
            }
            .listRowInsets(insets)
        }
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
    let files: [ReviewFile]
    let insets: EdgeInsets
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(theme.secondary)
            Spacer(minLength: 4)
            Text("^[\(files.count) file](inflect: true)")
                .foregroundStyle(theme.secondary)
            Text("+\(files.compactMap(\.additions).reduce(0, +)) −\(files.compactMap(\.deletions).reduce(0, +))")
                .foregroundStyle(theme.secondary)
                .padding(.trailing, 14)
        }
        .font(.subheadline)
        .frame(height: 22)
        .listRowInsets(insets)
    }
}
