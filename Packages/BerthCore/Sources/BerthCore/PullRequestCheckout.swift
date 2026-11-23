import Foundation

public struct PullRequestHead: Sendable, Equatable {
    public let branch: String
    public let owner: String?
    public let isCrossRepository: Bool

    public init(branch: String, owner: String?, isCrossRepository: Bool) {
        self.branch = branch
        self.owner = owner
        self.isCrossRepository = isCrossRepository
    }
}

public enum PullRequestCheckout {
    public struct Failure: Error, Equatable, Sendable {
        public let message: String
    }

    public static func viewArguments(repository: String, number: Int) -> [String] {
        ["pr", "view", String(number), "--repo", repository, "--json", "headRefName,headRepositoryOwner,isCrossRepository"]
    }

    public static func parseHead(_ output: Data) -> PullRequestHead? {
        struct Response: Decodable {
            struct Owner: Decodable {
                let login: String
            }

            let headRefName: String
            let headRepositoryOwner: Owner?
            let isCrossRepository: Bool
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: output), !response.headRefName.isEmpty else { return nil }

        return PullRequestHead(branch: response.headRefName, owner: response.headRepositoryOwner?.login, isCrossRepository: response.isCrossRepository)
    }

    public static func worktreePath(root: String, branch: String) -> String {
        let main = URL(filePath: root, directoryHint: .isDirectory).standardizedFileURL
        let folder = branch.replacing("/", with: "-").replacing("\\", with: "-")
        return main.deletingLastPathComponent().appending(path: "\(main.lastPathComponent).worktrees").appending(path: folder).path
    }

    static func worktrees(porcelain: String) -> [(path: String, branch: String?)] {
        porcelain.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n")
            guard let path = lines.first(where: { $0.hasPrefix("worktree ") }) else { return nil }

            let branch = lines.first { $0.hasPrefix("branch refs/heads/") }
            return (String(path.dropFirst("worktree ".count)), branch.map { String($0.dropFirst("branch refs/heads/".count)) })
        }
    }

    public static func prepare(root: String, number: Int, head: PullRequestHead) async throws -> String {
        let sha: String
        do {
            _ = try await ReviewGit.git(["check-ref-format", "--branch", head.branch], in: root, timeout: 10)
            _ = try await ReviewGit.git(["fetch", "origin", "pull/\(number)/head"], in: root, timeout: 120)
            sha = try await line(["rev-parse", "FETCH_HEAD"], in: root)
        } catch {
            throw failure("Couldn’t fetch PR #\(number) from origin", error)
        }

        do {
            let entries = try await worktrees(porcelain: line(["worktree", "list", "--porcelain"], in: root))
            let branch = try await localBranch(for: head, root: root, entries: entries)
            if let held = entries.first(where: { $0.branch == branch }) {
                guard FileManager.default.fileExists(atPath: held.path) else {
                    throw Failure(message: "The worktree for \(branch) was removed from disk. Run git worktree prune in the repository, then try again.")
                }

                _ = try? await ReviewGit.git(["merge", "--ff-only", "--quiet", sha], in: held.path, timeout: 60)
                return held.path
            }

            let path = worktreePath(root: root, branch: branch)
            guard !FileManager.default.fileExists(atPath: path) else {
                throw Failure(message: "\((path as NSString).abbreviatingWithTildeInPath) already exists and is not a worktree for \(branch).")
            }

            let exists = await (try? line(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: root)) != nil
            _ = try await ReviewGit.git(exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path, sha], in: root, timeout: 120)
            if exists {
                _ = try? await ReviewGit.git(["merge", "--ff-only", "--quiet", sha], in: path, timeout: 60)
            } else if !head.isCrossRepository, await (try? ReviewGit.git(["fetch", "origin", branch], in: root, timeout: 60)) != nil {
                _ = try? await ReviewGit.git(["branch", "--set-upstream-to=origin/\(branch)", branch], in: path, timeout: 10)
            }
            return path
        } catch let error as Failure {
            throw error
        } catch {
            throw failure("Couldn’t create the worktree for PR #\(number)", error)
        }
    }

    private static func localBranch(for head: PullRequestHead, root: String, entries: [(path: String, branch: String?)]) async throws -> String {
        let own = URL(filePath: worktreePath(root: root, branch: head.branch)).resolvingSymlinksInPath().path
        let isOurs = entries.contains { $0.branch == head.branch && URL(filePath: $0.path).resolvingSymlinksInPath().path == own }
        guard head.isCrossRepository, let owner = head.owner, !isOurs,
              await (try? line(["rev-parse", "--verify", "--quiet", "refs/heads/\(head.branch)"], in: root)) != nil
        else { return head.branch }

        let prefixed = "\(owner)/\(head.branch)"
        _ = try await ReviewGit.git(["check-ref-format", "--branch", prefixed], in: root, timeout: 10)
        return prefixed
    }

    private static func line(_ arguments: [String], in root: String) async throws -> String {
        try await String(decoding: ReviewGit.git(arguments, in: root, timeout: 30), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func failure(_ summary: String, _ error: any Error) -> Failure {
        guard case let ReviewGitError.git(_, message) = error, let first = message.split(separator: "\n").first else { return Failure(message: "\(summary).") }

        return Failure(message: "\(summary). \(first)")
    }
}
