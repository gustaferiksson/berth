import SwiftUI

enum Octicon: String {
    case pullRequest = "git-pull-request"
    case pullRequestDraft = "git-pull-request-draft"
    case pullRequestClosed = "git-pull-request-closed"
    case merge = "git-merge"
    case mergeQueue = "git-merge-queue"
    case issueOpened = "issue-opened"
    case issueClosed = "issue-closed"
    case skip
    case check
    case x
    case dotFill = "dot-fill"
    case comment
    case branch = "git-branch"

    func assetName(size: CGFloat = 16) -> String {
        "octicon-\(rawValue)-\(size > 16 ? 24 : 16)"
    }
}

struct OcticonImage: View {
    let octicon: Octicon
    let size: CGFloat

    init(_ octicon: Octicon, size: CGFloat = 12) {
        self.octicon = octicon
        self.size = size
    }

    var body: some View {
        Image(octicon.assetName(size: size))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
