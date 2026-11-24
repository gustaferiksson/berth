import BerthCore
import SwiftUI

enum SidebarStyle: String, CaseIterable {
    case classic, slim

    static let key = "sidebarStyle"

    var title: String { rawValue.capitalized }
}

extension EnvironmentValues {
    @Entry var sidebarStyle = SidebarStyle.classic
    @Entry var showsSlimRowActions = false
}

struct SlimSessionRow: View {
    let session: SessionSummary
    let projectName: String?
    let status: StatusSlot
    let isLocked: Bool
    let isFlagged: Bool
    let context: SessionContext?
    let pullRequest: PullRequest?
    let morePullRequests: Int
    let suggestion: String?
    let issue: IssueRef?
    let isArchived: Bool
    let isSnoozed: Bool
    var watch: PullRequestWatch?
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.showsSlimRowActions) private var showsActions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if let projectName {
                line(projectName: projectName)
            }
            line(projectName: nil)
        }
        .frame(minHeight: 28)
    }

    private func line(projectName: String?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                status
                SlimRowTitle(title: session.title, isUnread: status.isUnread, isSecondary: isArchived || isSnoozed)
                    .help(issue.map { "Issue \($0.repository)#\($0.number)" } ?? "")
                    .layoutPriority(1)
                if let suggestion {
                    SlimGlyph(symbol: "sparkle", title: suggestion)
                }
                if isFlagged {
                    SlimGlyph(symbol: "flag.fill", title: "Flagged", color: theme.closed)
                }
                if isLocked {
                    SlimGlyph(symbol: "lock.fill", title: "Running in another terminal")
                        .accessibilityHidden(true)
                }
                if let context, let window = context.window, window > 0, Double(context.tokens) / Double(window) >= 0.7 {
                    ContextRing(context: context, window: window)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue([session.agent.harness.isOptIn ? session.agent.harness.name : nil, isLocked ? "locked, running in another terminal" : nil].compactMap(\.self).joined(separator: ", "))
            .layoutPriority(1)

            if let watch {
                SlimGlyph(symbol: "eye", title: watch.title)
            } else if let pullRequest {
                SlimPullRequestGlyph(pullRequest: pullRequest, more: morePullRequests)
                    .fixedSize()
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

    @ViewBuilder private var actions: some View {
        if isArchived {
            SlimRowButton(title: "Mark as Not Done", symbol: "arrow.uturn.backward") { store.unarchive(session.id) }
        } else {
            SlimRowButton(title: "Mark as Done", symbol: "checkmark") { store.archive(session.id) }
        }
    }
}

struct SlimTaskRow: View {
    let task: SessionTask
    let isExpanded: Bool
    let state: RowState?
    let isUnread: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusSlot(state: nil, isUnread: false, chevron: isExpanded ? "chevron.down" : "chevron.right")
            SlimRowTitle(title: task.title, isUnread: !isExpanded && isUnread)
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
    }
}

struct SlimTabRow: View {
    let title: String
    let state: RowState?
    let isTerminal: Bool
    var watch: PullRequestWatch?

    var body: some View {
        HStack(spacing: 6) {
            StatusSlot(state: state, isUnread: false, isOpen: !isTerminal, isTerminal: isTerminal)
            SlimRowTitle(title: title)
            if let watch {
                Spacer(minLength: 0)
                SlimGlyph(symbol: "eye", title: watch.title)
            }
        }
        .frame(minHeight: 28)
    }
}

struct SlimGroupHeader<Accessory: View, Rename: View>: View {
    let title: String
    let help: String
    let count: Int?
    let tint: Color?
    @Binding var isExpanded: Bool
    @ViewBuilder let accessory: (Bool) -> Accessory
    let rename: Rename?
    @State private var isHovering = false

    var body: some View {
        let highlightsHeader = isHovering || Snapshot.forcedHover.contains(title)
        HStack(spacing: 6) {
            if let rename {
                chevron(highlightsHeader)
                rename
                Spacer(minLength: 0)
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        chevron(highlightsHeader)
                        Text(title)
                            .lineLimit(1)
                        if !isExpanded, let count {
                            Text(count, format: .number)
                                .font(.caption.monospacedDigit())
                                .fixedSize()
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(help)
                .accessibilityValue(isExpanded ? "expanded" : "collapsed")
            }
            accessory(highlightsHeader)
                .opacity(highlightsHeader ? 1 : 0)
                .allowsHitTesting(highlightsHeader)
                .accessibilityHidden(!highlightsHeader)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(tint ?? Color.secondary)
        .frame(minHeight: 20)
        .contentShape([.interaction, .dragPreview], .rect(cornerRadius: 6))
        .onHover { isHovering = $0 }
    }

    private func chevron(_ highlighted: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .opacity(highlighted ? 1 : 0.32)
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}

struct SlimShowMore: View {
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

private struct SlimRowTitle: View {
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

private struct SlimGlyph: View {
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

private struct SlimRowButton: View {
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

private struct SlimPullRequestGlyph: View {
    let pullRequest: PullRequest
    let more: Int
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let checks = [.open, .draft].contains(pullRequest.state) ? pullRequest.checks : nil
        let label = "Open pull request #\(pullRequest.number), \(pullRequest.state.rawValue)\(checks.map { ", checks \($0.rawValue)" } ?? "")\(more > 0 ? ", \(more) more on this session" : "")"
        Button {
            openURL(pullRequest.url)
        } label: {
            Image(systemName: "arrow.triangle.pull")
                .font(.caption)
                .foregroundStyle(pullRequest.state.color(in: theme))
                .frame(width: 14, height: 16)
                .overlay(alignment: .topTrailing) {
                    if checks == .failed {
                        Circle().fill(theme.closed)
                            .frame(width: 5, height: 5)
                    } else if checks == .running {
                        Circle().trim(from: 0, to: 0.75)
                            .stroke(theme.needsYou, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                            .frame(width: 5, height: 5)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .pointerStyle(.link)
        .help(label)
        .accessibilityLabel(label)
    }
}
