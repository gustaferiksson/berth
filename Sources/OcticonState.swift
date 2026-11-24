import BerthCore

extension Octicon {
    init(_ state: PullRequestState) {
        switch state {
        case .open: self = .pullRequest
        case .draft: self = .pullRequestDraft
        case .merged: self = .merge
        case .closed: self = .pullRequestClosed
        }
    }

    init(_ state: IssueState?) {
        switch state {
        case .completed: self = .issueClosed
        case .notPlanned: self = .skip
        case .open, nil: self = .issueOpened
        }
    }
}
