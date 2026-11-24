import AppKit
import BerthCore
import SwiftUI

struct ReviewPullRequestDetails: View {
    let pullRequest: PullRequest
    @State private var preview: ItemPreview?
    @State private var isLoading = true
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            PullRequestStatePill(pullRequest: pullRequest, opensOnGitHub: false)
                            Text(verbatim: "#\(pullRequest.number)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(preview?.title ?? pullRequest.title)
                            .font(.headline)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open on GitHub", systemImage: "arrow.up.right") { openURL(pullRequest.url) }
                        .controlSize(.small)
                        .fixedSize()
                }
                if let preview {
                    sections(preview)
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading Pull Request Details")
                } else {
                    Text("Pull request details are unavailable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: pullRequest.url) {
            guard let reference = ItemReference(url: pullRequest.url) else {
                isLoading = false
                return
            }

            let loaded = await ItemPreviewCache.shared.preview(for: reference)
            guard !Task.isCancelled else { return }

            preview = loaded
            isLoading = false
        }
    }

    private func sections(_ preview: ItemPreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ReviewPullRequestDetailsSection(title: "Linked issue") {
                if let issue = preview.related.first(where: { !$0.isPullRequest }),
                   let url = IssueRef(repository: issue.repository, number: issue.number).url {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            OcticonImage(issue.state == "OPEN" ? .issueOpened : .issueClosed)
                            Text(verbatim: "\(issue.repository)#\(issue.number)")
                                .foregroundStyle(.secondary)
                            Text(issue.title)
                        }
                    }
                } else {
                    Text("No linked issue").foregroundStyle(.secondary)
                }
            }
            ReviewPullRequestDetailsSection(title: "Description") {
                if preview.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No description").foregroundStyle(.secondary)
                } else {
                    markdown(preview.body)
                }
            }
            ReviewPullRequestDetailsSection(title: "Reviewers") {
                if preview.reviewers.isEmpty {
                    Text("No reviewers").foregroundStyle(.secondary)
                }
                ForEach(preview.reviewers.enumerated(), id: \.offset) { _, reviewer in
                    let appearance = reviewer.state.appearance(in: theme)
                    HStack(spacing: 6) {
                        Image(systemName: appearance.icon)
                            .foregroundStyle(appearance.color)
                            .accessibilityHidden(true)
                        Text(reviewer.login)
                        Spacer()
                        Text(appearance.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ReviewPullRequestDetailsSection(title: "Latest comments") {
                if preview.comments.isEmpty {
                    Text("No comments").foregroundStyle(.secondary)
                }
                ForEach(preview.comments.reversed().enumerated(), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(comment.author ?? "ghost")
                                .fontWeight(.semibold)
                            Text(age(since: comment.createdAt))
                                .foregroundStyle(.secondary)
                                .help(comment.createdAt.formatted())
                        }
                        .font(.caption)
                        markdown(comment.body)
                    }
                    .padding(.bottom, 4)
                }
            }
            ReviewPullRequestDetailsSection(title: "Checks") {
                let checks = preview.checks?.items ?? []
                if checks.isEmpty {
                    Text("No checks").foregroundStyle(.secondary)
                }
                ForEach(checks.enumerated(), id: \.offset) { _, check in
                    let appearance = check.outcome.appearance(in: theme)
                    HStack(spacing: 6) {
                        Image(systemName: appearance.icon)
                            .foregroundStyle(appearance.color)
                            .accessibilityHidden(true)
                        Text(check.name)
                        Spacer()
                        Text(appearance.label)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func markdown(_ source: String) -> some View {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let rendered = MarkdownAttributedString.render(MarkdownBlock.blocks(in: source), theme: theme, proseFont: font)
        let attributed = (try? AttributedString(rendered, including: \.appKit)) ?? AttributedString(rendered.string)
        return Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReviewPullRequestDetailsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
