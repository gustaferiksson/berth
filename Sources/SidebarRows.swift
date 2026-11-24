import BerthCore
import GhosttyTerminal
import SwiftUI

extension EnvironmentValues {
    @Entry var showsRowActions = false
}

enum SidebarRowLayout {
    static let horizontalInset = 16.0
}

struct SessionRow: View {
    let session: SessionSummary
    let projectName: String?
    let live: LiveSession?
    let watch: PullRequestWatch?
    let isOpen: Bool
    let isLocked: Bool
    let hasBackgroundShell: Bool
    let isUnread: Bool
    let isFlagged: Bool
    let context: SessionContext?
    let pullRequest: PullRequest?
    let morePullRequests: Int
    let suggestion: String?
    let issue: IssueRef?
    let isArchived: Bool
    let isSnoozed: Bool
    @Binding var showsLockedNotice: Bool
    @AppStorage("sidebarTwoLineRows") private var showsTwoLines = false
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.showsRowActions) private var showsActions
    private static let columnSpacing = 6.0

    var body: some View {
        content
            .frame(minHeight: 28)
            .popover(isPresented: $showsLockedNotice, arrowEdge: .trailing) {
                Text("“\(session.title)” is running in another terminal. Quit it there to open it here, so the transcript isn’t written by two processes.")
                    .font(.callout)
                    .frame(width: 280)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }
    }

    @ViewBuilder private var content: some View {
        if showsTwoLines {
            VStack(alignment: .leading, spacing: 4) {
                line(projectName: nil)
                repoAndBranch
                    .padding(.leading, StatusSlot.width + Self.columnSpacing)
            }
            .padding(.vertical, 8)
        } else if let projectName {
            ViewThatFits(in: .horizontal) {
                line(projectName: projectName)
                line(projectName: nil)
            }
        } else {
            line(projectName: nil)
        }
    }

    private func line(projectName: String?) -> some View {
        let state = RowState(live: live)
        return HStack(spacing: Self.columnSpacing) {
            HStack(spacing: Self.columnSpacing) {
                StatusSlot(state: state, isUnread: isUnread, isOpen: isOpen, hasBackgroundShell: hasBackgroundShell)
                RowTitle(title: session.title, isUnread: isUnread, isSecondary: isArchived || isSnoozed)
                    .help(issue.map { "Issue \($0.repository)#\($0.number)" } ?? "")
                    .layoutPriority(1)
                if let suggestion {
                    RowGlyph(symbol: "sparkle", title: suggestion)
                }
                if isFlagged {
                    RowGlyph(symbol: "flag.fill", title: "Flagged", color: theme.closed)
                }
                if isLocked {
                    RowGlyph(symbol: "lock.fill", title: "Running in another terminal")
                        .accessibilityHidden(true)
                }
                if let context, let window = context.window, window > 0, Double(context.tokens) / Double(window) >= 0.7 {
                    ContextRing(context: context, window: window)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue([session.agent.harness.isOptIn ? session.agent.harness.name : nil, isLocked ? "locked, running in another terminal" : nil].compactMap(\.self).joined(separator: ", "))
            .layoutPriority(1)

            if let watch, state == nil {
                RowGlyph(symbol: "eye", title: watch.title)
            } else if let pullRequest {
                let checks = [.open, .draft].contains(pullRequest.state) ? pullRequest.checks : nil
                let label = "Open pull request #\(pullRequest.number), \(pullRequest.state.rawValue)\(checks.map { ", checks \($0.rawValue)" } ?? "")\(morePullRequests > 0 ? ", \(morePullRequests) more on this session" : "")"
                PullRequestTag(pullRequest: pullRequest, more: morePullRequests)
                    .fixedSize()
                    .accessibilityLabel(label)
                    .modifier(ItemPreviewTrigger(reference: ItemReference(url: pullRequest.url), placement: .sidebar, store: store))
            }

            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if let projectName {
                        Text(projectName)
                            .help(projectName)
                    }
                    Text(age(since: session.lastPrompt))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .opacity(showsActions ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: showsActions)
                .allowsHitTesting(!showsActions)
                .accessibilityHidden(showsActions)

                if showsActions {
                    HStack(spacing: 6) { actions }
                }
            }
            .frame(minWidth: 14, alignment: .trailing)
            .fixedSize()
        }
    }

    private var repoAndBranch: some View {
        let repo = Text(verbatim: URL(filePath: session.checkout).lastPathComponent)
        let details = session.branch.map { branch in
            Text("\(repo) · \(Text(verbatim: branch).foregroundStyle(theme.branch.opacity(0.8)))")
        } ?? repo

        return details
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder private var actions: some View {
        if isArchived {
            RowActionButton(title: "Mark as Not Done", symbol: "arrow.uturn.backward") { store.unarchive(session.id) }
        } else {
            RowActionButton(title: "Mark as Done", symbol: "checkmark") { store.archive(session.id) }
        }
    }
}

struct TaskRow: View {
    let task: SessionTask
    let isExpanded: Bool
    let state: RowState?
    let isUnread: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusSlot(state: nil, isUnread: false, chevron: isExpanded ? "chevron.down" : "chevron.right")
            RowTitle(title: task.title, isUnread: !isExpanded && isUnread)
                .help(task.issue.map { "\(task.title) · Issue \($0.repository)#\($0.number)" } ?? task.title)
            if !isExpanded, state != nil || isUnread {
                MemberDot(state: state)
                    .scaleEffect(state == .working ? 0.875 : 1)
                    .fixedSize()
            }
            Text(task.sessions.count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("^[\(task.sessions.count) session](inflect: true)")
                .accessibilityLabel("^[\(task.sessions.count) session](inflect: true)")
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

struct TabRow: View {
    let tab: Tab
    let live: LiveSession?
    var watch: PullRequestWatch?
    @ObservedObject var terminal: TerminalViewState

    var body: some View {
        let state = RowState(live: live)
        HStack(spacing: 6) {
            StatusSlot(state: state, isUnread: false, isOpen: tab.kind != .shell, isTerminal: tab.kind == .shell)
            RowTitle(title: tab.title(terminalTitle: terminal.title, sessionTitle: nil))
            if let watch, state == nil {
                Spacer(minLength: 0)
                RowGlyph(symbol: "eye", title: watch.title)
            }
        }
        .frame(minHeight: 28)
        .accessibilityValue(tab.agent.harness.isOptIn ? tab.agent.harness.name : "")
    }
}

struct ShowMoreRow: View {
    let isExpanded: Bool
    let hiddenCount: Int
    let toggle: () -> Void

    var body: some View {
        Button(isExpanded ? "Show less" : "\(hiddenCount) more", action: toggle)
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.leading, 20)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
    }
}

private struct RowTitle: View {
    let title: String
    var isUnread = false
    var isSecondary = false

    var body: some View {
        Text(title)
            .font(.body.weight(isUnread ? .semibold : .regular))
            .foregroundStyle(isSecondary ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RowGlyph: View {
    let symbol: String
    let title: String
    var color = Color.secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .fixedSize()
            .help(title)
            .accessibilityLabel(title)
    }
}

private struct RowActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}
