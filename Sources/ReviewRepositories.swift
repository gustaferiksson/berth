import BerthCore
import SwiftUI

struct ReviewTaskCard: View {
    let title: String
    let issue: IssueRef?
    let members: [SessionSummary]
    let currentID: String
    let pullRequestCount: Int
    let repositoryCount: Int
    @Binding var isExpanded: Bool
    let activate: (String) -> Void
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 10)
                        .accessibilityLabel(isExpanded ? "Collapse Task" : "Expand Task")
                    if let issue { IssueTag(issue: issue).fixedSize() }
                    Text(title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(title)
                    if !isExpanded {
                        Text("^[\(repositoryCount) repo](inflect: true)")
                            .font(.caption)
                            .foregroundStyle(theme.secondary)
                            .fixedSize()
                    }
                }
                .padding(.leading, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if isExpanded {
                Text("^[\(members.count) session](inflect: true) · \(pullRequestCount) \(pullRequestCount == 1 ? "PR" : "PRs") · ^[\(repositoryCount) repo](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(members.prefix(6)) { member in
                        Button { activate(member.id) } label: {
                            HStack(spacing: 8) {
                                Text(member.title)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(URL(filePath: member.checkout).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(theme.secondary)
                                    .lineLimit(1)
                            }
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
                            .foregroundStyle(theme.secondary)
                            .frame(height: 22)
                    }
                }
                .padding(.top, 4)
                .overlay(alignment: .top) { Hairline(axis: .horizontal) }
                .padding(.top, 2)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.unread.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.unread.opacity(0.3)))
    }
}

struct ReviewRepoTabs: View {
    let tabs: [(id: String, title: String)]
    @Binding var selection: String
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(tabs, id: \.id) { tab in
                    Button { selection = tab.id } label: {
                        Text(tab.title)
                            .font(.caption)
                            .fontWeight(selection == tab.id ? .semibold : .regular)
                            .foregroundStyle(selection == tab.id ? theme.foreground : theme.secondary)
                            .lineLimit(1)
                            .frame(height: 24)
                            .overlay(alignment: .bottom) {
                                if selection == tab.id { Rectangle().fill(theme.foreground).frame(height: 2) }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 24)
        .padding(.bottom, 4)
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
    let indent: Double
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(theme.secondary)
            Text(files.count, format: .number)
                .monospacedDigit()
                .foregroundStyle(theme.secondary.opacity(0.6))
            Spacer(minLength: 4)
            Text("+\(files.compactMap(\.additions).reduce(0, +)) −\(files.compactMap(\.deletions).reduce(0, +))")
                .monospacedDigit()
                .foregroundStyle(theme.secondary)
                .padding(.trailing, 14)
        }
        .font(.system(size: 11))
        .frame(height: 20)
        .listRowInsets(EdgeInsets(top: 2, leading: -8 - indent, bottom: 0, trailing: 8))
    }
}
