import BerthCore
import SwiftUI

struct ReviewSinceMenu: View {
    let model: ReviewModel
    let changes: ReviewChanges
    let pullRequest: (repository: String, number: Int)?
    @State private var recent: [ReviewCommit] = []
    @State private var lastReview: PullRequestOwnReview?
    @State private var asksRef = false
    @State private var ref = ""

    var body: some View {
        HStack(spacing: 3) {
            Menu {
                if let pullRequest, let lastReview {
                    Button("Since Your Last Review (\(lastReview.date.formatted(.dateTime.day().month(.abbreviated))))") {
                        Task { if let failure = await model.sinceLastReview(repository: pullRequest.repository, number: pullRequest.number) { model.notice = failure } }
                    }
                    Divider()
                }
                ForEach(recent, id: \.sha) { commit in
                    Button("\(commit.sha) \(commit.subject)") { Task { await model.setSince(commit.sha) } }
                }
                Divider()
                Button("Compare with…") {
                    ref = ""
                    asksRef = true
                }
            } label: {
                HStack(spacing: 3) {
                    if let since = changes.since {
                        Text("since \(since.shortSHA)")
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .accessibilityLabel("Compare since")
                    }
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Show only what changed since a commit")
            if changes.since != nil {
                Button("Clear Since", systemImage: "xmark.circle.fill") { Task { await model.setSince(nil) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Compare against the base again")
            }
        }
        .task(id: pullRequest?.number) { lastReview = await model.ownReview(pullRequest) }
        .task(id: changes.head) { recent = await (try? ReviewGit.recentCommits(of: changes)) ?? [] }
        .alert("Compare With", isPresented: $asksRef) {
            TextField("Commit, tag or branch", text: $ref)
            Button("Compare") {
                let typed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { if await !model.setSince(typed) { model.notice = "Couldn’t find “\(typed)” in this repository" } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Show only what changed since this commit, tag or branch.")
        }
    }
}

extension ReviewModel {
    @discardableResult
    func setSince(_ ref: String?) async -> Bool {
        since = ref
        await load()
        return ref == nil || since != nil
    }
}

extension ReviewModel {
    func ownReview(_ pullRequest: (repository: String, number: Int)?) async -> PullRequestOwnReview? {
        guard let pullRequest else { return nil }

        if Snapshot.output != nil { return UserDefaults.standard.string(forKey: "snapshotReviewOwnReviewCommit").map { PullRequestOwnReview(commit: $0, date: Date(timeIntervalSince1970: 1_795_350_600)) } }

        return await Task.detached { PullRequestStatus.ownReview(repository: pullRequest.repository, number: pullRequest.number) }.value
    }

    func sinceLastReview(repository: String, number: Int) async -> String? {
        guard let review = await ownReview((repository, number)) else { return "No submitted review of yours found on pull request #\(number)" }

        let root = changes?.root ?? folder
        let isLocal = await ReviewGit.ensureCommit(review.commit, pullRequest: number, in: root)
        guard Snapshot.output != nil || isLocal else {
            return "Your last review was on a commit that isn’t in this clone anymore (\(review.commit.prefix(7)))"
        }

        return await setSince(review.commit) ? nil : "Couldn’t compare since your last review (\(review.commit.prefix(7)))"
    }
}
