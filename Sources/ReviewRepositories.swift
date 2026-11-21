import BerthCore
import SwiftUI

struct ReviewTaskHeader: View {
    let title: String
    let issue: IssueRef?
    let members: [SessionSummary]
    let currentID: String
    let pullRequestCount: Int
    let repositoryCount: Int
    @Binding var isExpanded: Bool
    let activate: (String) -> Void
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let state = issue.map(store.state(of:))
        let color = state == .open ? theme.working : state == .completed ? theme.merged : Color.secondary
        let repositories = members.reduce(into: [String]()) { names, member in
            let name = URL(filePath: member.checkout).lastPathComponent
            if !names.contains(name) { names.append(name) }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if issue != nil {
                    Image(systemName: state == .completed ? "checkmark.circle.fill" : state == .notPlanned ? "slash.circle.fill" : "smallcircle.filled.circle")
                        .font(.title3)
                        .foregroundStyle(color)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .help(title)
            }
            if let issue {
                Group {
                    if let url = issue.url {
                        Link("#\(issue.number) · \(issue.repository)", destination: url)
                    } else {
                        Text(verbatim: "#\(issue.number) · \(issue.repository)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .help("Open issue \(issue.repository)#\(issue.number)")
            }
            HStack(spacing: 4) {
                ForEach(repositories.prefix(3), id: \.self) { name in
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                }
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
                            Text(URL(filePath: member.checkout).lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                                .layoutPriority(-1)
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
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReviewRepoTabs: View {
    let tabs: [(id: String, title: String)]
    @Binding var selection: String

    var body: some View {
        let options = ForEach(tabs, id: \.id) { Text($0.title).tag($0.id) }
        Group {
            if tabs.count <= 4 {
                Picker("Repository", selection: $selection) { options }
                    .pickerStyle(.segmented)
            } else {
                Picker("Repository", selection: $selection) { options }
                    .pickerStyle(.menu)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

struct ReviewOtherPullRequests: View {
    let pullRequests: [PullRequest]
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ForEach(pullRequests, id: \.number) { pullRequest in
            HStack(spacing: 6) {
                PullRequestTag(pullRequest: pullRequest)
                    .fixedSize()
                Text(pullRequest.title)
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .help(pullRequest.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
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
        .font(.subheadline)
        .frame(height: 22)
        .listRowInsets(EdgeInsets(top: 2, leading: -8 - indent, bottom: 0, trailing: 8))
    }
}
