import SwiftUI

struct PullRequestPreparingBanner: View {
    let count: Int
    let number: Int?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(number.map { "Setting up the worktree for PR #\($0)" } ?? "Setting up worktrees for \(count) pull requests")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(16)
    }
}
