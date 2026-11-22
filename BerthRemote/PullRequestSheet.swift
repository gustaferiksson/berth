import SwiftUI

struct PullRequestSheet: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let session = client.groups.lazy.flatMap(\.sessions).first { $0.id == sessionID }
        let load = client.pullRequests[sessionID]

        NavigationStack {
            List {
                switch load {
                case let .loaded(detail):
                    PullRequestContent(detail: detail)

                case .failed:
                    Section {
                        ContentUnavailableView {
                            Label("Couldn’t Load Pull Request", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Berth couldn’t reach GitHub for this pull request.")
                        } actions: {
                            Button("Try Again") {
                                client.loadPullRequest(of: sessionID)
                            }
                            if let url = session?.pullRequest?.url, url.scheme == "https" {
                                Link("Open on GitHub", destination: url)
                            }
                        }
                    }

                case nil:
                    Section {
                        ProgressView("Loading")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
            .navigationTitle(session?.pullRequest.map { "Pull Request #\(String($0.number))" } ?? "Pull Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: client.state) {
                guard client.state == .connected else { return }

                client.loadPullRequest(of: sessionID)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PullRequestContent: View {
    let detail: RemotePullRequestDetail

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(detail.title)
                    .font(.title3.bold())
                HStack(spacing: 8) {
                    PullRequestStatePill(state: detail.state)
                    Text([detail.repository, "#\(detail.number)"].compactMap(\.self).joined())
                        .font(.footnote)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                if let head = detail.head, let base = detail.base {
                    Text("\(head) \(Text(Image(systemName: "arrow.right")).accessibilityLabel("into")) \(base)")
                        .font(.footnote)
                        .monospaced()
                        .foregroundStyle(.secondary)
                } else if let branch = detail.head ?? detail.base {
                    Text(branch)
                        .font(.footnote)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            if let checks = detail.checks {
                LabeledContent("Checks") {
                    Text("\(Text(Image(systemName: ChecksStyle.symbol(checks))).accessibilityLabel(ChecksStyle.title(checks))) \(checksSummary(detail))")
                        .foregroundStyle(ChecksStyle.color(checks))
                }
            }
            if let decision = detail.reviewDecision {
                LabeledContent("Review") {
                    Text(reviewTitle(decision))
                        .foregroundStyle(decision == "APPROVED" ? .green : decision == "CHANGES_REQUESTED" ? .red : .secondary)
                }
            }
            if let threads = detail.unresolvedThreads {
                LabeledContent("Open Threads", value: threads.formatted())
            }
        }
        if let additions = detail.additions, let deletions = detail.deletions {
            Section("Changes") {
                LabeledContent("Lines") {
                    Text("\(Text("+\(additions.formatted())").foregroundStyle(.green)) \(Text("−\(deletions.formatted())").foregroundStyle(.red))")
                        .monospacedDigit()
                }
                if let files = detail.changedFiles {
                    LabeledContent("Files", value: files.formatted())
                }
                if let commits = detail.commits {
                    LabeledContent("Commits", value: commits.formatted())
                }
            }
        }
        if detail.url.scheme == "https" {
            Section {
                Link(destination: detail.url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private func checksSummary(_ detail: RemotePullRequestDetail) -> String {
        let counts = [("passed", detail.checksPassed), ("failed", detail.checksFailed), ("running", detail.checksRunning)]
            .compactMap { name, count in count.flatMap { $0 > 0 ? "\($0) \(name)" : nil } }
        return counts.isEmpty ? ChecksStyle.title(detail.checks ?? "") : counts.joined(separator: ", ")
    }

    private func reviewTitle(_ decision: String) -> String {
        switch decision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes Requested"
        case "REVIEW_REQUIRED": "Review Required"
        default: decision.capitalized
        }
    }
}

private struct PullRequestStatePill: View {
    let state: String

    var body: some View {
        let color: Color = state == "Open" ? .green : state == "Merged" ? .purple : state == "Closed" ? .red : .gray
        Text(state)
            .font(.footnote.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: .rect(cornerRadius: 6))
    }
}

enum ChecksStyle {
    static func symbol(_ state: String) -> String {
        state == "passed" ? "checkmark.circle.fill" : state == "failed" ? "xmark.circle.fill" : "clock.fill"
    }

    static func color(_ state: String) -> Color {
        state == "passed" ? .green : state == "failed" ? .red : .orange
    }

    static func title(_ state: String) -> String {
        state == "passed" ? "Checks passed" : state == "failed" ? "Checks failed" : "Checks running"
    }
}
