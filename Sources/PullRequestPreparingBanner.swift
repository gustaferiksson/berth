import SwiftUI

struct PullRequestPreparingBanner: View {
    let count: Int
    let number: Int?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(number.map { "Preparing a worktree for PR #\($0)" } ?? "Preparing worktrees for \(count) pull requests")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(16)
    }
}
