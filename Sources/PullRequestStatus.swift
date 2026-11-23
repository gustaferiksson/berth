import BerthCore
import Foundation

nonisolated struct PullRequest: Sendable, Hashable {
    let number: Int
    let url: URL
    let title: String
    let state: PullRequestState
    var baseRefName: String?
    var headRefName: String?
    var checks: PullRequestChecks.State?
    var closingIssues: [ClosingIssue] = []
    var reviewDecision: InboxPullRequest.ReviewDecision?
}

nonisolated enum IssueState: Sendable {
    case open
    case completed
    case notPlanned
}

nonisolated struct ClosingIssue: Sendable, Hashable {
    let ref: IssueRef
    let title: String
    var state: IssueState?
}

nonisolated struct SessionPullRequest: PullRequestCandidate, Hashable {
    let repository: String
    let pullRequest: PullRequest
    let head: String?

    var number: Int { pullRequest.number }
    var state: PullRequestState { pullRequest.state }
}

nonisolated struct PullRequestBranch: Sendable, Hashable {
    let repository: String
    let branch: String
}

nonisolated enum PullRequestStatus {
    private static let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func head(of link: PullRequestLink) -> PullRequestHead? {
        guard let gh, let output = run(gh, arguments: PullRequestCheckout.viewArguments(repository: link.repository, number: link.number), requireSuccess: true) else { return nil }

        return PullRequestCheckout.parseHead(output)
    }

    private struct Response: Decodable {
        struct Payload: Decodable {
            let info: Info?
            let branches: [String: Connection?]?
            let numbers: [String: Node?]?
        }

        struct Info: Decodable {
            struct Ref: Decodable {
                let name: String
            }

            let nameWithOwner: String
            let defaultBranchRef: Ref?
        }

        struct Connection: Decodable {
            let nodes: [Node]
        }

        struct Node: Decodable {
            struct Repository: Decodable {
                let nameWithOwner: String
            }

            struct Rollup: Decodable {
                let state: String
            }

            struct Issue: Decodable {
                let number: Int
                let title: String
                let state: String?
                let stateReason: String?
                let repository: Repository
            }

            struct Closing: Decodable {
                let nodes: [Issue]
            }

            let number: Int
            let url: URL
            let title: String
            let state: String
            let isDraft: Bool
            let baseRefName: String?
            let headRefName: String?
            let headRepository: Repository?
            let statusCheckRollup: Rollup?
            let reviewDecision: String?
            let closingIssuesReferences: Closing?
        }

        let data: Payload?
    }

    static func fetch(_ branches: Set<PullRequestBranch>, linked: Set<PullRequestLink>) async -> (branches: [PullRequestBranch: PullRequest?], linked: [PullRequestLink: PullRequest]) {
        guard let gh else { return ([:], [:]) }

        return await withTaskGroup(of: (branches: [PullRequestBranch: PullRequest?], linked: [PullRequestLink: PullRequest]).self) { group in
            for repository in Set(branches.map(\.repository) + linked.map(\.repository)) {
                let names = branches.filter { $0.repository == repository }.map(\.branch)
                let numbers = linked.filter { $0.repository == repository }.map(\.number)
                group.addTask { fetch(branches: names, numbers: numbers, in: repository, gh: gh) }
            }
            return await group.reduce(into: ([:], [:])) { results, fetched in
                results.branches.merge(fetched.branches) { $1 }
                results.linked.merge(fetched.linked) { $1 }
            }
        }
    }

    private static let nodeFields = "number url title state isDraft baseRefName headRefName headRepository { nameWithOwner } statusCheckRollup { state } reviewDecision closingIssuesReferences(first: 5) { nodes { number title state stateReason repository { nameWithOwner } } }"

    private static func fetch(branches: [String], numbers: [Int], in repository: String, gh: String) -> (branches: [PullRequestBranch: PullRequest?], linked: [PullRequestLink: PullRequest]) {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil }) else { return ([:], [:]) }

        let target = "repository(owner: \"\(parts[0])\", name: \"\(parts[1])\")"
        let variables = (branches.indices.map { "$b\($0): String!" } + numbers.indices.map { "$n\($0): Int!" }).joined(separator: ", ")
        let branchFields = branches.indices.map { "b\($0): pullRequests(headRefName: $b\($0), first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { \(nodeFields) } }" }.joined(separator: " ")
        let numberFields = numbers.indices.map { "n\($0): pullRequest(number: $n\($0)) { \(nodeFields) }" }.joined(separator: " ")
        let query = "query(\(variables)) { info: \(target) { nameWithOwner defaultBranchRef { name } } \(branches.isEmpty ? "" : "branches: \(target) { \(branchFields) }") \(numbers.isEmpty ? "" : "numbers: \(target) { \(numberFields) }") }"
        let arguments = ["api", "graphql", "-f", "query=\(query)"] + branches.enumerated().flatMap { ["-f", "b\($0.offset)=\($0.element)"] } + numbers.enumerated().flatMap { ["-F", "n\($0.offset)=\($0.element)"] }
        guard let output = run(gh, arguments: arguments),
              let payload = (try? JSONDecoder().decode(Response.self, from: output))?.data,
              let info = payload.info
        else { return ([:], [:]) }

        let found = branches.enumerated().reduce(into: [PullRequestBranch: PullRequest?]()) { results, item in
            guard let connection = payload.branches?["b\(item.offset)"] ?? nil else { return }

            let own = connection.nodes.filter { $0.headRepository?.nameWithOwner == info.nameWithOwner }
            let node = item.element == info.defaultBranchRef?.name ? nil : own.first { $0.state == "OPEN" } ?? own.first
            results[PullRequestBranch(repository: repository, branch: item.element)] = .some(node.map(pullRequest))
        }
        let linked = numbers.enumerated().reduce(into: [PullRequestLink: PullRequest]()) { results, item in
            guard let node = payload.numbers?["n\(item.offset)"] ?? nil else { return }

            results[PullRequestLink(repository: repository, number: item.element)] = pullRequest(node)
        }
        return (found, linked)
    }

    private static func pullRequest(_ node: Response.Node) -> PullRequest {
        let state: PullRequestState = node.state == "MERGED" ? .merged : node.state == "CLOSED" ? .closed : node.isDraft ? .draft : .open
        return PullRequest(number: node.number, url: node.url, title: node.title, state: state, baseRefName: node.baseRefName, headRefName: node.headRefName, checks: node.statusCheckRollup.map { PullRequestChecks.State($0.state) }, closingIssues: node.closingIssuesReferences?.nodes.map { ClosingIssue(ref: IssueRef(repository: $0.repository.nameWithOwner, number: $0.number), title: $0.title, state: IssueState(state: $0.state, reason: $0.stateReason)) } ?? [], reviewDecision: node.reviewDecision.flatMap(InboxPullRequest.ReviewDecision.init(rawValue:)))
    }

    static func inbox() -> [InboxPullRequest]? {
        guard let gh, let output = run(gh, arguments: PullRequestInbox.arguments) else { return nil }

        return PullRequestInbox.parse(output)
    }

    static func issueInbox() -> [InboxIssue]? {
        guard let gh, let output = run(gh, arguments: IssueInbox.arguments, requireSuccess: true) else { return nil }

        return IssueInbox.parse(output)
    }

    static func linkedPullRequests(issue: IssueReference) -> Result<[LinkedPullRequest], IssuePullRequests.LookupError> {
        guard let gh else { return .failure(.missingCLI) }
        guard let output = run(gh, arguments: IssuePullRequests.arguments(issue: issue)) else { return .failure(.requestFailed) }

        return IssuePullRequests.parse(output)
    }

    static func detail(repository: String, number: Int) -> PullRequestDetail? {
        guard let gh, let arguments = PullRequestDetail.arguments(repository: repository, number: number), let output = run(gh, arguments: arguments) else { return nil }

        return PullRequestDetail.parse(output)
    }

    static func reply(repository: String, threadID: String, body: String) -> Bool {
        guard let gh, let target = reviewTarget(gh, nodeID: threadID, repository: repository) else { return false }

        let reviewID: String
        if let pending = target.pendingReviewID {
            reviewID = pending
        } else {
            let query = "mutation($id: ID!) { addPullRequestReview(input: {pullRequestId: $id}) { pullRequestReview { id state } } }"
            let result = reviewData(gh, arguments: ["api", "graphql", "-f", "query=\(query)", "-f", "id=\(target.pullRequestID)"])?["addPullRequestReview"] as? NSDictionary
            guard let review = result?["pullRequestReview"] as? NSDictionary,
                  review["state"] as? String == "PENDING",
                  let id = review["id"] as? String
            else { return false }

            reviewID = id
        }

        let arguments = ReviewThread.replyArguments(threadID: threadID, body: body) + ["-f", "reviewID=\(reviewID)"]
        let result = reviewData(gh, arguments: arguments)?["addPullRequestReviewThreadReply"] as? NSDictionary
        return (result?["comment"] as? NSDictionary)?["id"] is String
    }

    static func addThread(pullRequestID: String, comment: ReviewComment) -> Bool {
        guard let gh, let target = reviewTarget(gh, nodeID: pullRequestID) else { return false }

        let arguments = ReviewThread.newThreadArguments(pullRequestID: pullRequestID, comment: comment) + (target.pendingReviewID.map { ["-f", "reviewID=\($0)"] } ?? [])
        let result = reviewData(gh, arguments: arguments)?["addPullRequestReviewThread"] as? NSDictionary
        return (result?["thread"] as? NSDictionary)?["id"] is String
    }

    private static func reviewTarget(_ gh: String, nodeID: String, repository: String? = nil) -> (pullRequestID: String, pendingReviewID: String?)? {
        let query = "query($id: ID!) { node(id: $id) { ...ReviewTarget ... on PullRequestReviewThread { pullRequest { ...ReviewTarget } } } } fragment ReviewTarget on PullRequest { id repository { nameWithOwner } reviews(first: 100, states: [PENDING]) { nodes { id viewerDidAuthor } } }"
        guard let node = reviewData(gh, arguments: ["api", "graphql", "-f", "query=\(query)", "-f", "id=\(nodeID)"])?["node"] as? NSDictionary else { return nil }

        let pullRequest = node["pullRequest"] as? NSDictionary ?? node
        guard let pullRequestID = pullRequest["id"] as? String,
              let name = (pullRequest["repository"] as? NSDictionary)?["nameWithOwner"] as? String,
              repository == nil || name.lowercased() == repository?.lowercased()
        else { return nil }

        let reviews = ((pullRequest["reviews"] as? NSDictionary)?["nodes"] as? NSArray)?.compactMap { $0 as? NSDictionary }
        return (pullRequestID, reviews?.first(where: { $0["viewerDidAuthor"] as? Bool == true })?["id"] as? String)
    }

    private static func reviewData(_ gh: String, arguments: [String]) -> NSDictionary? {
        guard let output = run(gh, arguments: arguments, requireSuccess: true),
              let response = (try? JSONSerialization.jsonObject(with: output)) as? NSDictionary,
              response["errors"] == nil
        else { return nil }

        return response["data"] as? NSDictionary
    }

    private static func run(_ executable: String, arguments: [String], requireSuccess: Bool = false) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return !requireSuccess || process.terminationStatus == 0 ? data : nil
    }
}

extension IssueState {
    nonisolated init?(state: String?, reason: String?) {
        if state == "OPEN" { self = .open } else if state == "CLOSED" { self = reason == "COMPLETED" ? .completed : .notPlanned } else { return nil }
    }
}
