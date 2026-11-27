import Foundation

public struct PullRequestOwnReview: Sendable, Equatable {
    public let commit: String
    public let date: Date

    public init(commit: String, date: Date) {
        self.commit = commit
        self.date = date
    }

    public static let query = "query($owner: String!, $name: String!, $number: Int!) { viewer { login } repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviews(last: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) { nodes { submittedAt author { login } commit { oid } } } } } }"

    private struct Response: Decodable {
        struct Payload: Decodable {
            struct Account: Decodable {
                let login: String
            }

            struct Review: Decodable {
                struct Commit: Decodable {
                    let oid: String
                }

                let submittedAt: String?
                let author: Account?
                let commit: Commit?
            }

            struct Reviews: Decodable {
                let nodes: [Review?]?
            }

            struct PullRequest: Decodable {
                let reviews: Reviews?
            }

            struct Repository: Decodable {
                let pullRequest: PullRequest?
            }

            let viewer: Account?
            let repository: Repository?
        }

        let data: Payload?
    }

    public static func arguments(repository: String, number: Int) -> [String]? {
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }

        return ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])", "-F", "number=\(number)"]
    }

    public static func parse(_ output: Data) -> Self? {
        guard let payload = (try? JSONDecoder().decode(Response.self, from: output))?.data, let viewer = payload.viewer?.login else { return nil }

        let formatter = ISO8601DateFormatter()
        let own = (payload.repository?.pullRequest?.reviews?.nodes ?? []).compactMap { review -> Self? in
            guard let review, review.author?.login == viewer, let commit = review.commit?.oid, let submitted = review.submittedAt, let date = formatter.date(from: submitted) else { return nil }

            return Self(commit: commit, date: date)
        }
        return own.max { $0.date < $1.date }
    }
}
