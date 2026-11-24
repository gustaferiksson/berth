import BerthCore
import SwiftUI

struct ProjectEntry: Identifiable {
    let header: String?
    let count: Int
    let project: String?
    let item: ProjectItem

    var id: String { item.id }
}

struct ProjectItemRow: View {
    let item: ProjectItem
    let project: String?
    let sessions: Int
    let isHighlighted: Bool
    @Environment(\.ghosttyTheme) private var theme

    private var symbol: LauncherGlyph {
        switch item.kind {
        case .issue: .octicon(.issueOpened)
        case .pullRequest: .octicon(.pullRequest)
        case .draft: "square.and.pencil"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .issue: theme.working
        case .pullRequest: .accentColor
        case .draft: .secondary
        }
    }

    private var secondary: [String] {
        let reference = item.repository.flatMap { repository in item.number.map { "\(repository) #\($0)" } }
        return [
            reference,
            item.assignees.isEmpty ? nil : item.assignees.prefix(2).map { "@\($0)" }.joined(separator: " "),
            project,
            item.updatedAt.map { age(since: $0) },
        ].compactMap(\.self)
    }

    var body: some View {
        LauncherRowFrame(symbol: symbol, tint: tint, title: item.title, secondary: secondary, isHighlighted: isHighlighted) {
            HStack(spacing: 5) {
                if item.kind == .draft || item.isDraftPullRequest { LauncherBadge("Draft") }
                if sessions > 0 { LauncherBadge(String(sessions), symbol: "bubble.left") }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .opacity(item.kind == .draft ? 0.6 : 1)
    }
}

struct ProjectMoveNotice: View {
    let failure: ProjectsModel.MoveFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(failure == .needsScope ? "Changing a status needs the project permission" : "Couldn’t change the status")
            if failure == .needsScope {
                Text(ProjectQueries.writeScopeCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProjectNotice: View {
    let state: ProjectsModel.State
    let hasProjects: Bool
    let isFiltered: Bool

    var body: some View {
        switch state {
        case .needsScope:
            LauncherMessage(symbol: "lock", title: "GitHub needs the read:project permission", detail: ProjectQueries.refreshScopeCommand + "\nRun it in a terminal. Berth never runs it for you.")
                .textSelection(.enabled)

        case .noCLI:
            LauncherMessage(symbol: "terminal", title: "Install the GitHub CLI (gh) and sign in")

        case .loading where !hasProjects:
            LauncherMessage(symbol: "checklist", title: "Loading project items…", isLoading: true)

        case .failed where !hasProjects:
            LauncherMessage(symbol: "exclamationmark.circle", title: "Couldn’t load project items")

        default:
            LauncherMessage(
                symbol: "checklist",
                title: hasProjects ? isFiltered ? "No matching items" : "No open items" : "Choose projects in Settings",
                detail: hasProjects ? nil : "Settings, GitHub"
            )
        }
    }
}

struct ProjectMoveToStatusMenu: View {
    let item: ProjectItem
    @AppStorage(ProjectsModel.allowsEditingKey) private var allowsEditing = false
    @Environment(Store.self) private var store

    var body: some View {
        if allowsEditing, let board = store.projects.boards[item.projectID], board.statusFieldID != nil, !board.statusOptions.isEmpty {
            Menu("Move To Status") {
                ForEach(board.statusOptions, id: \.id) { option in
                    Button(option.name) { store.projects.move(item, to: option) }
                        .disabled(option.id == item.statusOptionID)
                }
            }
        }
    }
}
