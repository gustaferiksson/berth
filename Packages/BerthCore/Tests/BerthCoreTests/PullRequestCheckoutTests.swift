@testable import BerthCore
import Foundation
import Testing

final class PullRequestCheckoutTests {
    private let base = FileManager.default.temporaryDirectory.appending(path: "berth-pr-\(UUID().uuidString)").resolvingSymlinksInPath()

    init() throws {
        ReviewGitTests.isolatedGitConfig
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func git(_ repo: URL, _ arguments: String...) async throws -> String {
        try await String(decoding: ReviewGit.git(arguments, in: repo.path), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ repo: URL, _ file: String) async throws {
        try file.write(to: repo.appending(path: file), atomically: true, encoding: .utf8)
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", file)
    }

    private func remote(prHead branch: String = "feature/login-fix", number: Int = 7) async throws -> (origin: URL, checkout: URL) {
        let origin = base.appending(path: "origin.git")
        let seed = base.appending(path: "seed")
        let checkout = base.appending(path: "widgets")
        for folder in [origin, seed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try await git(origin, "init", "--quiet", "--bare", "-b", "main")
        try await git(seed, "init", "--quiet", "-b", "main")
        try await commit(seed, "one")
        try await git(seed, "remote", "add", "origin", origin.path)
        try await git(seed, "push", "--quiet", "origin", "main")
        try await git(seed, "checkout", "--quiet", "-b", branch)
        try await commit(seed, "two")
        try await git(seed, "push", "--quiet", "origin", "\(branch):refs/pull/\(number)/head", "\(branch):refs/heads/\(branch)")
        try await git(base, "clone", "--quiet", origin.path, checkout.path)
        return (origin, checkout)
    }

    private func advance(_: URL, to branch: String, number: Int) async throws {
        let seed = base.appending(path: "seed")
        try await commit(seed, "three")
        try await git(seed, "push", "--quiet", "origin", "\(branch):refs/pull/\(number)/head", "\(branch):refs/heads/\(branch)")
    }

    @Test func pathFollowsWorktrunkTemplate() {
        #expect(PullRequestCheckout.worktreePath(root: "/Users/me/Repos/widgets", branch: "feature/login-fix") == "/Users/me/Repos/widgets.worktrees/feature-login-fix")
        #expect(PullRequestCheckout.worktreePath(root: "/Users/me/Repos/widgets/", branch: "a\\b") == "/Users/me/Repos/widgets.worktrees/a-b")
    }

    @Test func parsesHeadAndPorcelain() {
        let json = Data(#"{"headRefName":"fix","headRepositoryOwner":{"login":"octo"},"isCrossRepository":true}"#.utf8)
        #expect(PullRequestCheckout.parseHead(json) == PullRequestHead(branch: "fix", owner: "octo", isCrossRepository: true))
        #expect(PullRequestCheckout.parseHead(Data("{}".utf8)) == nil)

        let porcelain = "worktree /r/widgets\nHEAD abc\nbranch refs/heads/main\n\nworktree /r/widgets.worktrees/x\nHEAD def\ndetached\n"
        let entries = PullRequestCheckout.worktrees(porcelain: porcelain)
        #expect(entries.map(\.path) == ["/r/widgets", "/r/widgets.worktrees/x"])
        #expect(entries.map(\.branch) == ["main", nil])
    }

    @Test func opensFreshWorktreeOnHeadBranchThenReusesAndFastForwards() async throws {
        let (origin, checkout) = try await remote()
        let head = PullRequestHead(branch: "feature/login-fix", owner: "acme", isCrossRepository: false)

        let path = try await PullRequestCheckout.prepare(root: checkout.path, number: 7, head: head)
        #expect(path == base.appending(path: "widgets.worktrees/feature-login-fix").path)
        #expect(try await git(URL(filePath: path), "branch", "--show-current") == "feature/login-fix")
        #expect(try await git(URL(filePath: path), "rev-parse", "--abbrev-ref", "feature/login-fix@{upstream}") == "origin/feature/login-fix")

        try await advance(origin, to: "feature/login-fix", number: 7)
        let again = try await PullRequestCheckout.prepare(root: checkout.path, number: 7, head: head)
        #expect(URL(filePath: again).resolvingSymlinksInPath() == URL(filePath: path).resolvingSymlinksInPath())
        #expect(FileManager.default.fileExists(atPath: URL(filePath: path).appending(path: "three").path))
    }

    @Test func reusesExistingBranchWithoutWorktree() async throws {
        let (_, checkout) = try await remote()
        try await git(checkout, "branch", "feature/login-fix", "origin/main")

        let path = try await PullRequestCheckout.prepare(root: checkout.path, number: 7, head: PullRequestHead(branch: "feature/login-fix", owner: nil, isCrossRepository: false))
        #expect(try await git(URL(filePath: path), "branch", "--show-current") == "feature/login-fix")
        #expect(FileManager.default.fileExists(atPath: URL(filePath: path).appending(path: "two").path))
    }

    @Test func forkHeadNamedMainGetsOwnerPrefix() async throws {
        let (_, checkout) = try await remote(prHead: "main-copy")
        let head = PullRequestHead(branch: "main", owner: "octo", isCrossRepository: true)

        let path = try await PullRequestCheckout.prepare(root: checkout.path, number: 7, head: head)
        #expect(path == base.appending(path: "widgets.worktrees/octo-main").path)
        #expect(try await git(URL(filePath: path), "branch", "--show-current") == "octo/main")
        #expect(try await git(checkout, "rev-parse", "main") == git(checkout, "rev-parse", "origin/main"))
    }

    @Test func slugCollisionFailsWithoutTouchingTheOtherWorktree() async throws {
        let (_, checkout) = try await remote()
        let other = PullRequestHead(branch: "feature-login-fix", owner: nil, isCrossRepository: false)
        _ = try await PullRequestCheckout.prepare(root: checkout.path, number: 7, head: other)

        await #expect(throws: PullRequestCheckout.Failure.self) {
            try await PullRequestCheckout.prepare(root: checkout.path, number: 7, head: PullRequestHead(branch: "feature/login-fix", owner: nil, isCrossRepository: false))
        }
    }

    @Test func missingPullRequestRefReportsFetchFailure() async throws {
        let (_, checkout) = try await remote()

        let failure = await #expect(throws: PullRequestCheckout.Failure.self) {
            try await PullRequestCheckout.prepare(root: checkout.path, number: 99, head: PullRequestHead(branch: "gone", owner: nil, isCrossRepository: false))
        }
        #expect(failure?.message.hasPrefix("Couldn’t fetch PR #99 from origin") == true)
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "widgets.worktrees").path))
    }

    private func fakeWorktrunk(_ body: String) throws -> String {
        let script = base.appending(path: "wt")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test func worktrunkPathComesFromItsJSON() async throws {
        let worktrunk = try fakeWorktrunk(#"echo "◎ Fetching PR #7..." >&2; echo '{"action":"created","branch":"b","path":"/tmp/widgets.worktrees/b"}'"#)

        let path = try await PullRequestCheckout.prepare(root: base.path, number: 7, worktrunk: worktrunk)

        #expect(path == "/tmp/widgets.worktrees/b")
    }

    @Test func worktrunkFailureShowsItsReason() async throws {
        let worktrunk = try fakeWorktrunk(#"echo "◎ Fetching PR #7..." >&2; echo "✗ No GitHub remote configured" >&2; exit 1"#)

        let failure = await #expect(throws: PullRequestCheckout.Failure.self) {
            try await PullRequestCheckout.prepare(root: base.path, number: 7, worktrunk: worktrunk)
        }
        #expect(failure?.message == "Worktrunk couldn’t set up a worktree for PR #7. No GitHub remote configured")
    }
}
