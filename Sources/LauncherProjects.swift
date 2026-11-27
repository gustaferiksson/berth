import BerthCore
import SwiftUI

struct ProjectEntry: Identifiable {
    let header: String?
    let count: Int
    let project: String?
    let item: ProjectItem

    var id: String { item.id }
}

struct ProjectSection {
    let name: String
    let title: String
    let total: Int
    let items: [ProjectItem]
    let projectTitles: [String: String]
}

struct ProjectColumnBar: View {
    let columns: [(name: String, count: Int)]
    let selection: String?
    let select: (String?) -> Void
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        if columns.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip("All", count: columns.reduce(0) { $0 + $1.count }, isSelected: selection == nil) { select(nil) }
                    ForEach(columns, id: \.name) { column in
                        chip(column.name, count: column.count, isSelected: selection == column.name) { select(column.name) }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 12)
        }
    }

    private func chip(_ title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text(String(count)).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(isSelected ? Color.accentColor.opacity(0.25) : theme.foreground.opacity(0.09), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
        .help("Show \(title)")
    }
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
        [
            item.assignees.isEmpty ? nil : item.assignees.prefix(2).map { "@\($0)" }.joined(separator: " "),
            project,
        ].compactMap(\.self)
    }

    private var metadata: String {
        let reference = item.repository.flatMap { repository in item.number.map { "\(repository) #\($0)" } }
        return [reference, item.updatedAt.map { age(since: $0) }].compactMap(\.self).joined(separator: " · ")
    }

    var body: some View {
        LauncherRowFrame(symbol: symbol, tint: tint, title: item.title, secondary: secondary, isHighlighted: isHighlighted) {
            HStack(spacing: 8) {
                if !metadata.isEmpty { LauncherRowDetail(metadata) }
                if item.kind == .draft || item.isDraftPullRequest { LauncherRowDetail("Draft") }
                if sessions > 0 { LauncherRowDetail(String(sessions), symbol: "bubble.left") }
            }
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
        let options = store.projects.statusOptions(for: item, allowsEditing: allowsEditing)
        if !options.isEmpty {
            Menu("Move To Status") {
                ForEach(options, id: \.id) { option in
                    Button(option.name) { store.projects.move(item, to: option) }
                        .disabled(option.id == item.statusOptionID)
                }
            }
        }
    }
}

extension ProjectsModel {
    func statusOptions(for item: ProjectItem, allowsEditing: Bool) -> [ProjectStatusOption] {
        guard allowsEditing, let board = boards[item.projectID], board.statusFieldID != nil else { return [] }

        return board.statusOptions
    }
}
