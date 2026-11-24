import BerthCore
import Foundation
import SwiftUI

struct ItemPreviewActions {
    var openInBerth: (() -> Void)?
    var openInBerthTitle = "Open in Berth"
    var openInBerthDisabledReason: String?
    var steward: (() -> Void)?
    let copyLink: () -> Void
    let openOnGitHub: () -> Void
}

struct ItemPreviewView: View {
    static let width: CGFloat = 440

    let preview: ItemPreview
    let actions: ItemPreviewActions

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var checksExpanded: Bool
    @State private var nodes: [MarkdownNode]?

    init(preview: ItemPreview, actions: ItemPreviewActions, checksExpanded: Bool = false, initialNodes: [MarkdownNode]? = nil) {
        self.preview = preview
        self.actions = actions
        _checksExpanded = State(initialValue: checksExpanded)
        _nodes = State(initialValue: initialNodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            authorRow
            if !preview.labels.isEmpty {
                FlowLayout {
                    ForEach(preview.labels, id: \.name) { label in
                        labelChip(label)
                    }
                }
            }
            people
            if preview.kind == .pullRequest {
                if preview.additions != nil || preview.deletions != nil || preview.changedFiles != nil { stats }
                if let checks = preview.checks, !checks.items.isEmpty { checksBlock(checks) }
            }
            if !preview.related.isEmpty { related }
            Divider()
            description
            if preview.commentCount > 0 || !preview.comments.isEmpty { comments }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .textSelection(.disabled)
        .task(id: preview.body) {
            let source = preview.body
            let parsed = await Task.detached { Self.markdownNodes(in: source) }.value
            guard !Task.isCancelled else { return }

            nodes = parsed
        }
    }

    nonisolated static func markdownNodes(in source: String) -> [MarkdownNode] {
        let cleaned = source.replacing(/(?s)<!--.*?(?:-->|$)/, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? [] : MarkdownDocument.nodes(in: cleaned)
    }

    private var header: some View {
        let color: Color
        let icon: String
        let title: String
        switch (preview.kind, preview.state) {
        case (.pullRequest, .open):
            (color, icon, title) = (PullRequestState.open.color(in: theme), "arrow.triangle.pull", "Open")
        case (.pullRequest, .draft):
            (color, icon, title) = (PullRequestState.draft.color(in: theme), "arrow.triangle.pull", "Draft")
        case (.pullRequest, .merged):
            (color, icon, title) = (PullRequestState.merged.color(in: theme), "arrow.triangle.merge", "Merged")
        case (.pullRequest, _):
            (color, icon, title) = (PullRequestState.closed.color(in: theme), "xmark.circle", "Closed")
        case (.issue, .open):
            (color, icon, title) = (theme.working, "circle", "Open")
        case (.issue, .completed):
            (color, icon, title) = (theme.merged, "checkmark.circle", "Completed")
        case (.issue, .notPlanned):
            (color, icon, title) = (.secondary, "slash.circle", "Not planned")
        case (.issue, _):
            (color, icon, title) = (.secondary, "slash.circle", "Closed")
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: icon).accessibilityHidden(true)
                    Text(title).fontWeight(.semibold)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.13), in: .capsule)
                Text(verbatim: "\(preview.repository) #\(preview.number)")
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("Updated \(preview.updatedAt.formatted(.relative(presentation: .numeric)))")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(preview.title)
                .font(.headline)
                .foregroundStyle(theme.foreground)
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var authorRow: some View {
        let login = preview.author?.login ?? "Unknown author"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ItemPreviewAvatar(login: preview.author?.login, url: preview.author?.avatarURL, size: 20)
                Text(login).fontWeight(.medium).lineLimit(1)
                Text("opened \(preview.createdAt.formatted(.relative(presentation: .numeric)))")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityElement(children: .combine)
            if preview.kind == .pullRequest, let head = preview.headRefName, let base = preview.baseRefName {
                HStack(spacing: 6) {
                    Text(head).truncationMode(.middle)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                    Text(base).truncationMode(.middle)
                }
                .font(.caption.monospaced())
                .lineLimit(1)
                .foregroundStyle(theme.foreground)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.foreground.opacity(0.07), in: .rect(cornerRadius: 5))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("From \(head) into \(base)")
            }
        }
        .font(.caption)
    }

    private func labelChip(_ label: ItemPreview.Label) -> some View {
        let rgb = RGB(hex: label.color)
        let surface = colorScheme == .dark ? 0.0 : 1.0
        let fill = rgb.map { rgb in
            RGB(red: rgb.red * 0.28 + surface * 0.72, green: rgb.green * 0.28 + surface * 0.72, blue: rgb.blue * 0.28 + surface * 0.72)
        }
        let foreground = fill.map { $0.luminance > 0.179 ? Color.black : .white } ?? theme.foreground
        return Text(label.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(fill?.color ?? theme.foreground.opacity(0.08), in: .capsule)
            .overlay(Capsule().strokeBorder(rgb?.color.opacity(0.35) ?? .clear))
    }

    @ViewBuilder private var people: some View {
        if !preview.assignees.isEmpty || !preview.reviewers.isEmpty || preview.reviewDecision != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !preview.assignees.isEmpty {
                    peopleRow("Assignees") {
                        ForEach(preview.assignees, id: \.self) { login in
                            person(login)
                        }
                    }
                }
                if !preview.reviewers.isEmpty {
                    peopleRow("Reviewers") {
                        ForEach(preview.reviewers.enumerated(), id: \.offset) { _, reviewer in
                            person(reviewer.login, reviewState: reviewer.state)
                        }
                    }
                }
                if let decision = preview.reviewDecision {
                    let summary = switch decision {
                    case .approved: "Approved"
                    case .changesRequested: "Changes requested"
                    case .reviewRequired: "Review required"
                    }
                    Text(summary)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Review decision \(summary)")
                }
            }
            .font(.caption)
        }
    }

    private func peopleRow(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            FlowLayout(spacing: 9, rowSpacing: 5) { content() }
        }
    }

    private func person(_ login: String, reviewState: ItemPreview.Reviewer.State? = nil) -> some View {
        HStack(spacing: 4) {
            ItemPreviewAvatar(login: login, size: 15)
            Text(login).lineLimit(1)
            if let reviewState {
                let appearance: (icon: String, label: String, color: Color) = switch reviewState {
                case .approved: ("checkmark.circle.fill", "Approved", theme.working)
                case .changesRequested: ("exclamationmark.circle.fill", "Changes requested", theme.needsYou)
                case .commented: ("text.bubble", "Commented", .secondary)
                case .requested: ("clock", "Review requested", .secondary)
                case .dismissed: ("minus.circle", "Dismissed", .secondary)
                }
                Image(systemName: appearance.icon)
                    .foregroundStyle(appearance.color)
                    .accessibilityLabel(appearance.label)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stats: some View {
        HStack(spacing: 8) {
            if let additions = preview.additions {
                Text("+\(additions)")
                    .foregroundStyle(theme.working)
                    .accessibilityLabel("\(additions) additions")
            }
            if let deletions = preview.deletions {
                Text("-\(deletions)")
                    .foregroundStyle(theme.closed)
                    .accessibilityLabel("\(deletions) deletions")
            }
            if let changedFiles = preview.changedFiles {
                Text(changedFiles == 1 ? "1 file" : "\(changedFiles) files")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func checksBlock(_ checks: ItemChecks) -> some View {
        let ordered = checks.items.filter { $0.outcome == .failed } + checks.items.filter { $0.outcome != .failed }
        let skipped = checks.items.count - checks.passed - checks.failed - checks.running
        let summary = [
            checks.passed > 0 ? "\(checks.passed) passed" : nil,
            checks.failed > 0 ? "\(checks.failed) failed" : nil,
            checks.running > 0 ? "\(checks.running) running" : nil,
        ].compactMap(\.self).joined(separator: ", ")
        let appearance = checkAppearance(checks.failed > 0 ? .failed : checks.running > 0 ? .running : checks.passed > 0 ? .passed : .skipped)
        return DisclosureGroup(isExpanded: $checksExpanded) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(ordered.prefix(12).enumerated(), id: \.offset) { _, check in
                    let appearance = checkAppearance(check.outcome)
                    HStack(spacing: 6) {
                        Image(systemName: appearance.icon)
                            .foregroundStyle(appearance.color)
                            .accessibilityLabel(appearance.label)
                        Text(check.name).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                if ordered.count > 12 {
                    Text("+\(ordered.count - 12) more")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
        } label: {
            HStack(spacing: 6) {
                Text("Checks").fontWeight(.semibold)
                Spacer(minLength: 2)
                Image(systemName: appearance.icon)
                    .foregroundStyle(appearance.color)
                    .accessibilityHidden(true)
                Text(summary.isEmpty ? "\(skipped) skipped" : summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(8)
        .background(theme.foreground.opacity(0.06), in: .rect(cornerRadius: 7))
    }

    private func checkAppearance(_ outcome: ItemChecks.Check.Outcome) -> (icon: String, label: String, color: Color) {
        switch outcome {
        case .passed: ("checkmark.circle.fill", "Passed", theme.working)
        case .failed: ("xmark.circle.fill", "Failed", theme.closed)
        case .running: ("clock", "Running", theme.needsYou)
        case .skipped: ("minus.circle", "Skipped", .secondary)
        }
    }

    private var related: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(preview.kind == .pullRequest ? "Closes" : "Closed by")
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            ForEach(preview.related.enumerated(), id: \.offset) { _, item in
                let path = item.isPullRequest ? "pull" : "issues"
                if let url = URL(string: "https://github.com/\(item.repository)/\(path)/\(item.number)") {
                    let state = item.state.capitalized.replacing("_", with: " ")
                    let color: Color = switch item.state.uppercased() {
                    case "OPEN": theme.working
                    case "MERGED", "COMPLETED": theme.merged
                    case "CLOSED": item.isPullRequest ? theme.closed : .secondary
                    default: .secondary
                    }
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(verbatim: "#\(item.number) \(item.title)")
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .foregroundStyle(theme.foreground)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityRemoveTraits(.isButton)
                    .accessibilityAddTraits(.isLink)
                    .help("\(item.repository) #\(String(item.number))")
                    .accessibilityLabel("\(item.title), \(item.repository) #\(String(item.number)), \(state)")
                }
            }
        }
        .font(.caption)
    }

    @ViewBuilder private var description: some View {
        if let nodes, !nodes.isEmpty {
            let style = ReviewStyle(scheme: .terminal, fontFamily: "", fontSize: 12, lineHeightMultiple: 1.3, ghostty: theme)
            let markdown = MarkdownRenderStyle(style: style, source: .preview, size: 12)
            let content = VStack(alignment: .leading, spacing: 8) {
                ForEach(nodes.prefix(10).enumerated(), id: \.offset) { _, node in
                    MarkdownNodeView(node: node, markdown: markdown)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            ItemPreviewDescriptionLayout(maxHeight: 260) {
                ViewThatFits(in: .vertical) {
                    if nodes.count <= 10 { content }
                    content.mask(alignment: .top) {
                        VStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 26)
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }
            .clipped()
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else { return .discarded }

                openURL(url)
                return .handled
            })
        } else if nodes != nil || preview.body.isEmpty {
            Text("No description provided.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preview.commentCount == 1 ? "1 comment" : "\(preview.commentCount) comments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(preview.comments.suffix(3).enumerated(), id: \.offset) { _, comment in
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                let plain = (try? AttributedString(markdown: comment.body, options: options)).map { String($0.characters) } ?? comment.body
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        ItemPreviewAvatar(login: comment.author, size: 15)
                        Text(comment.author ?? "Unknown author").fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(comment.createdAt.formatted(.relative(presentation: .numeric)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(plain)
                        .font(.system(size: 12))
                        .lineLimit(3)
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.foreground.opacity(0.06), in: .rect(cornerRadius: 7))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let openInBerth = actions.openInBerth {
                    Button(actions.openInBerthTitle, action: openInBerth)
                        .buttonStyle(.borderedProminent)
                        .help(actions.openInBerthTitle)
                    if let steward = actions.steward {
                        Button(StewardPullRequestButton.title, systemImage: "eye", action: steward)
                            .buttonStyle(.bordered)
                            .help("Open the session and ask Claude to steward this pull request")
                    }
                    Spacer(minLength: 0)
                }
                Button(action: actions.copyLink) {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .help("Copy the GitHub link")
                Button(action: actions.openOnGitHub) {
                    Label("Open on GitHub", systemImage: "arrow.up.right")
                }
                .labelStyle(.iconOnly)
                .help("Open this item on GitHub")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            if actions.openInBerth == nil, let reason = actions.openInBerthDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ItemPreviewPlaceholder: View {
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Capsule().frame(width: 58, height: 21)
                RoundedRectangle(cornerRadius: 4).frame(width: 110, height: 10)
            }
            RoundedRectangle(cornerRadius: 4).frame(width: 274, height: 14)
            HStack(spacing: 6) {
                Circle().frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 4).frame(width: 120, height: 10)
            }
        }
        .foregroundStyle(theme.foreground.opacity(0.12))
        .padding(16)
        .frame(width: ItemPreviewView.width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading item preview")
    }
}

private struct ItemPreviewAvatar: View {
    let login: String?
    var url: URL?
    let size: CGFloat

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initial
                    }
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var initial: some View {
        Text(login?.prefix(1).uppercased() ?? "?")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(theme.foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.foreground.opacity(0.10), in: .circle)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (view, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return subviews.map { view in
            let ideal = view.sizeThatFits(.unspecified)
            let size = ideal.width > width ? view.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}

private struct ItemPreviewDescriptionLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }

        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
