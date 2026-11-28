import BerthCore
import Foundation

#if DEBUG
enum SnapshotPullRequests {
    static let persists: Bool = {
        guard UserDefaults.standard.bool(forKey: "snapshotSessionPullRequestLinks") else { return false }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil, Bundle.main.bundleIdentifier != "dev.gustaf.berth" else {
            FileHandle.standardError.write(Data("snapshot: -snapshotSessionPullRequestLinks needs CFFIXED_USER_HOME and a copy of Berth.app with another bundle identifier, because CFFIXED_USER_HOME does not move UserDefaults\n".utf8))
            exit(1)
        }

        return true
    }()

    static func many(in repository: String) -> [PullRequestLink: PullRequest] {
        let count = max(UserDefaults.standard.integer(forKey: "snapshotManyPullRequests"), 0)
        let hoursAgo = [0, 0, 0, 1, 4, 8, 26, 30, 50, 60, 72, 84, 96, 108, 120, 132, 144] + (0..<count).map { 200 + $0 * 37 }
        return Dictionary(uniqueKeysWithValues: (0..<count).map { index in
            let number = 2000 + index
            let state: PullRequestState = index < 2 ? .open : index == 2 ? .draft : index % 11 == 7 ? .closed : .merged
            let closedAt = state == .open || state == .draft ? nil : Date.now.addingTimeInterval(-Double(hoursAgo[index]) * 3600)
            return (PullRequestLink(repository: repository, number: number), PullRequest(number: number, url: URL(string: "https://github.com/\(repository)/pull/\(number)")!, title: "Settlement export batch \(index + 1)", state: state, headRefName: "feature/settlement-batch-\(index + 1)", closedAt: closedAt))
        })
    }
}
#endif
