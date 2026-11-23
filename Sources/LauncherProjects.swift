import BerthCore
import SwiftUI

struct ProjectEntry: Identifiable {
    let header: String?
    let detail: String
    let project: String?
    let item: ProjectItem

    var id: String { item.id }
}

struct ProjectItemRow: View {
    let item: ProjectItem
    let project: String?
    let isMine: Bool
    let sessions: Int
    let isHighlighted: Bool
    @Environment(\.ghosttyTheme) private var theme

    private var symbol: String {
        switch item.kind {
        case .issue: "circle.dotted"
        case .pullRequest: "arrow.triangle.pull"
        case .draft: "square.and.pencil"
        }
    }

    private var reference: String {
        guard let repository = item.repository, let number = item.number else { return "Draft item" }

        return "\((repository as NSString).lastPathComponent) #\(number)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(isMine ? theme.foreground : theme.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(reference)
                    if item.isDraftPullRequest { Text("Draft") }
                    if let project { Text(project) }
                    if !item.assignees.isEmpty {
                        Text(verbatim: item.assignees.prefix(2).map { "@\($0)" }.joined(separator: " "))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if sessions > 0 {
                Text("^[\(sessions) session](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(theme.foreground)
            } else if item.kind == .draft {
                Text("Draft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let updatedAt = item.updatedAt {
                Text("Updated \(age(since: updatedAt))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }
}

struct ProjectNotice: View {
    let state: ProjectsModel.State
    let hasProjects: Bool
    let isFiltered: Bool

    var body: some View {
        VStack(spacing: 6) {
            switch state {
            case .needsScope:
                Text("GitHub needs the read:project permission")
                Text(ProjectQueries.refreshScopeCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("Run it in a terminal. Berth never runs it for you.")
                    .font(.caption)

            case .noCLI:
                Text("Install the GitHub CLI (gh) and sign in")

            case .loading:
                Text("Loading project items…")

            case .failed:
                Text("Couldn’t load project items")

            case .off, .ready:
                Text(hasProjects ? isFiltered ? "No matching items" : "No open items" : "Choose projects in Settings, GitHub")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 48)
    }
}
