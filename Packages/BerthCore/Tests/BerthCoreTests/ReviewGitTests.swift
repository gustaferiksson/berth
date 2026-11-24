@testable import BerthCore
import Foundation
import Testing

final class ReviewGitTests {
    static let isolatedGitConfig: Void = {
        let config = FileManager.default.temporaryDirectory.appending(path: "berth-review-gitconfig-\(UUID().uuidString)")
        try! "[user]\n\tname = Berth Tests\n\temail = tests@example.invalid\n[commit]\n\tgpgsign = false\n".write(to: config, atomically: true, encoding: .utf8)
        setenv("GIT_CONFIG_GLOBAL", config.path, 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    }()

    private let root = FileManager.default.temporaryDirectory.appending(path: "berth-review-\(UUID().uuidString)").resolvingSymlinksInPath()

    init() throws {
        Self.isolatedGitConfig
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ repo: URL, _ arguments: String...) async throws -> String {
        try await String(decoding: ReviewGit.git(arguments, in: repo.path), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func write(_ repo: URL, _ path: String, _ text: String) throws {
        try text.write(to: repo.appending(path: path), atomically: true, encoding: .utf8)
    }

    private func repo(_ name: String) async throws -> URL {
        let repo = root.appending(path: name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(repo, "init", "--quiet", "-b", "main")
        try write(repo, "keep.txt", "one\ntwo\n")
        try write(repo, "old.txt", "a\nb\nc\nd\ne\nf\n")
        try write(repo, "gone.txt", "bye\n")
        try write(repo, ".gitignore", "*.log\n")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "init")
        return repo
    }

    private func featureRepo() async throws -> URL {
        let repo = try await repo("feature")
        try await git(repo, "checkout", "--quiet", "-b", "feature")
        try write(repo, "committed.txt", "x\ny\nz\n")
        try Data([0, 1, 2, 3]).write(to: repo.appending(path: "logo.bin"))
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "feature work")
        try await git(repo, "mv", "old.txt", "renamed file.txt")
        try write(repo, "keep.txt", "one\ntwo\nthree\n")
        try FileManager.default.removeItem(at: repo.appending(path: "gone.txt"))
        try write(repo, "new.txt", "a\nb")
        try Data([9, 0, 9]).write(to: repo.appending(path: "image.bin"))
        try write(repo, "debug.log", "ignored\n")
        return repo
    }

    private func pushedFeatureRepo() async throws -> URL {
        let repo = try await repo("pushed")
        let origin = root.appending(path: "pushed-origin.git")
        try await git(root, "init", "--quiet", "--bare", "-b", "main", origin.path)
        try await git(repo, "remote", "add", "origin", origin.path)
        try await git(repo, "push", "--quiet", "-u", "origin", "main")
        try await git(repo, "remote", "set-head", "origin", "main")
        try await git(repo, "branch", "feature")

        try write(repo, "old.txt", "a\nb\nc\nd\ne\nf\ng\n")
        try await git(repo, "commit", "--quiet", "-am", "Main moves on")
        try await git(repo, "push", "--quiet", "origin", "main")

        try await git(repo, "checkout", "--quiet", "feature")
        try write(repo, "feature.txt", "first\n")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "Add the feature")
        try await git(repo, "push", "--quiet", "-u", "origin", "feature")
        try write(repo, "keep.txt", "one\ntwo\nthree\n")
        try await git(repo, "commit", "--quiet", "-am", "Extend keep")

        try write(repo, "keep.txt", "one\ntwo\nthree\nfour\n")
        try FileManager.default.removeItem(at: repo.appending(path: "gone.txt"))
        try write(repo, "notes.txt", "draft\n")
        return repo
    }

    @Test func checkoutMapsALinkedWorktreeOntoTheMainCheckout() async throws {
        let repo = try await repo("acme")
        try FileManager.default.createDirectory(at: repo.appending(path: "packages/core"), withIntermediateDirectories: true)
        let worktree = root.appending(path: "acme.worktrees/brave-otter")
        try await git(repo, "worktree", "add", "--quiet", "-b", "brave-otter", worktree.path)
        try FileManager.default.createDirectory(at: worktree.appending(path: "packages/core"), withIntermediateDirectories: true)
        #expect(RepositoryRoot.checkout(worktree.path) == repo.path)
        #expect(RepositoryRoot.checkout(worktree.appending(path: "packages/core").path) == repo.appending(path: "packages/core").path)
        #expect(RepositoryRoot.checkout(repo.appending(path: "packages/core").path) == repo.appending(path: "packages/core").path)
        #expect(RepositoryRoot.checkout(root.path) == root.path)
        #expect(RepositoryRoot.resolve(worktree.appending(path: "packages/core").path) == repo.path)
    }

    @Test func baseResolutionFollowsTheChain() async throws {
        let repo = try await repo("chain")
        try await git(repo, "branch", "develop")
        try await git(repo, "branch", "release")
        try await git(repo, "checkout", "--quiet", "-b", "feature")
        try await git(repo, "remote", "add", "origin", "/nonexistent/berth-origin.git")
        #expect(await ReviewGit.base(in: repo.path) == "main")

        try await git(repo, "update-ref", "refs/remotes/origin/main", "main")
        #expect(await ReviewGit.base(in: repo.path) == "origin/main")

        try await git(repo, "update-ref", "refs/remotes/origin/trunk", "main")
        try await git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
        #expect(await ReviewGit.base(in: repo.path) == "origin/trunk")

        try await git(repo, "update-ref", "refs/remotes/origin/feature", "feature")
        try await git(repo, "config", "branch.feature.remote", "origin")
        try await git(repo, "config", "branch.feature.merge", "refs/heads/feature")
        #expect(await ReviewGit.base(in: repo.path) == "origin/trunk")

        try await git(repo, "update-ref", "refs/remotes/origin/develop", "develop")
        try await git(repo, "config", "branch.feature.merge", "refs/heads/develop")
        #expect(await ReviewGit.base(in: repo.path) == "origin/develop")

        try await git(repo, "config", "branch.feature.gh-merge-base", "release")
        #expect(await ReviewGit.base(in: repo.path) == "release")

        try await git(repo, "update-ref", "refs/remotes/origin/release", "release")
        #expect(await ReviewGit.base(in: repo.path) == "origin/release")
    }

    @Test func masterIsTheLastFallback() async throws {
        let repo = try await repo("legacy")
        try await git(repo, "branch", "-m", "master")
        try await git(repo, "checkout", "--quiet", "-b", "feature")
        #expect(await ReviewGit.base(in: repo.path) == "master")
    }

    @Test func changesIncludeUntrackedRenamedAndBinaryWork() async throws {
        let repo = try await featureRepo()
        try FileManager.default.createDirectory(at: repo.appending(path: "empty"), withIntermediateDirectories: true)
        let changes = try await ReviewGit.changes(in: repo.appending(path: "empty").path)
        #expect(try await changes.root == git(repo, "rev-parse", "--show-toplevel"))
        #expect(changes.branch == "feature" && changes.base == "main")
        #expect(try await changes.mergeBase == git(repo, "rev-parse", "main"))
        #expect(changes.committed.map(\.path) == ["committed.txt", "logo.bin"])
        #expect(changes.uncommitted.map(\.path) == ["gone.txt", "image.bin", "keep.txt", "new.txt", "renamed file.txt"])
        #expect(changes.uncommitted.map(\.status) == [.deleted, .untracked, .modified, .untracked, .renamed])
        #expect(changes.uncommitted.first { $0.path == "renamed file.txt" }?.oldPath == "old.txt")
        #expect(changes.uncommitted.first { $0.path == "keep.txt" }.map { [$0.additions, $0.deletions] } == [1, 0])
        #expect(changes.uncommitted.first { $0.path == "new.txt" }.map { [$0.additions, $0.deletions] } == [2, 0])
        #expect(changes.committed.first { $0.path == "logo.bin" }.map { [$0.additions, $0.deletions] } == [nil, nil])
        #expect(changes.uncommitted.first { $0.path == "image.bin" }?.additions == nil)
        #expect(changes.fetchedAt == nil && changes.fetchError == nil)
    }

    @Test func contentsForEachSide() async throws {
        let repo = try await featureRepo()
        try Data(repeating: 65, count: 3 * 1024 * 1024).write(to: repo.appending(path: "huge.txt"))
        let changes = try await ReviewGit.changes(in: repo.path)
        let contents = { (path: String, compare: ReviewCompare) in
            let files = [.committed: changes.committed, .uncommitted: changes.uncommitted][compare] ?? []
            return try await ReviewGit.contents(of: #require(files.first { $0.path == path }), compare: compare, in: changes)
        }

        #expect(try await contents("new.txt", .uncommitted) == ReviewContents(original: nil, modified: .text("a\nb")))
        #expect(try await contents("gone.txt", .uncommitted) == ReviewContents(original: .text("bye\n"), modified: nil))
        #expect(try await contents("keep.txt", .uncommitted) == ReviewContents(original: .text("one\ntwo\n"), modified: .text("one\ntwo\nthree\n")))
        #expect(try await contents("renamed file.txt", .uncommitted) == ReviewContents(original: .text("a\nb\nc\nd\ne\nf\n"), modified: .text("a\nb\nc\nd\ne\nf\n")))
        #expect(try await contents("logo.bin", .committed) == ReviewContents(original: nil, modified: .binary))
        #expect(try await contents("huge.txt", .uncommitted) == ReviewContents(original: nil, modified: .tooLarge(bytes: 3 * 1024 * 1024)))
    }

    @Test func changesSplitUncommittedFromCommittedWork() async throws {
        let repo = try await pushedFeatureRepo()
        let changes = try await ReviewGit.changes(in: repo.path)
        #expect(try await changes.root == git(repo, "rev-parse", "--show-toplevel"))
        #expect(changes.branch == "feature" && !changes.isDefaultBranch && changes.base == "origin/main")
        #expect(try await changes.head == git(repo, "rev-parse", "HEAD"))
        #expect(try await changes.mergeBase == git(repo, "rev-parse", "main~1"))
        #expect(changes.fetchedAt != nil && changes.fetchError == nil)

        #expect(changes.uncommitted.map(\.path) == ["gone.txt", "keep.txt", "notes.txt"])
        #expect(changes.uncommitted.map(\.status) == [.deleted, .modified, .untracked])
        #expect(changes.uncommitted.map { [$0.additions, $0.deletions] } == [[0, 1], [1, 0], [1, 0]])
        #expect(changes.committed.map(\.path) == ["feature.txt", "keep.txt"])
        #expect(changes.committed.map(\.status) == [.added, .modified])
        #expect(changes.committed.map { [$0.additions, $0.deletions] } == [[1, 0], [1, 0]])
    }

    @Test func totalCountsEachPathAgainstTheMergeBaseWithUncommittedWork() async throws {
        let repo = try await pushedFeatureRepo()
        try FileManager.default.removeItem(at: repo.appending(path: "feature.txt"))
        try write(repo, "keep.txt", "one\ntwo\n")
        let changes = try await ReviewGit.changes(in: repo.path)
        #expect(changes.uncommitted.map { [$0.additions, $0.deletions] } == [[0, 1], [0, 1], [0, 1], [1, 0]])
        #expect(changes.committed.map { [$0.additions, $0.deletions] } == [[1, 0], [1, 0]])
        #expect(changes.total.map { [$0.additions, $0.deletions] } == [1, 1])

        let feature = try await ReviewGit.changes(in: featureRepo().path)
        #expect(feature.base == "main" && feature.total.map { [$0.additions, $0.deletions] } == [6, 1])
    }

    @Test func contentsFollowTheirCompareAndTheListedHead() async throws {
        let repo = try await pushedFeatureRepo()
        let changes = try await ReviewGit.changes(in: repo.path)
        try await git(repo, "commit", "--quiet", "-am", "Later work")
        let contents = { (path: String, compare: ReviewCompare) in
            let files = [.committed: changes.committed, .uncommitted: changes.uncommitted][compare] ?? []
            return try await ReviewGit.contents(of: #require(files.first { $0.path == path }), compare: compare, in: changes)
        }

        #expect(try await contents("keep.txt", .committed) == ReviewContents(original: .text("one\ntwo\n"), modified: .text("one\ntwo\nthree\n")))
        #expect(try await contents("feature.txt", .committed) == ReviewContents(original: nil, modified: .text("first\n")))
        #expect(try await contents("keep.txt", .uncommitted) == ReviewContents(original: .text("one\ntwo\nthree\n"), modified: .text("one\ntwo\nthree\nfour\n")))
        #expect(try await contents("gone.txt", .uncommitted) == ReviewContents(original: .text("bye\n"), modified: nil))
        #expect(try await contents("notes.txt", .uncommitted) == ReviewContents(original: nil, modified: .text("draft\n")))
    }

    @Test func branchStatusCountsAgainstTheBaseAndTheUpstream() async throws {
        let repo = try await pushedFeatureRepo()
        let status = try await ReviewGit.branchStatus(of: ReviewGit.changes(in: repo.path))
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.upstream == ReviewUpstream(name: "origin/feature", ahead: 1, behind: 0))
        #expect(status.commits.map(\.subject) == ["Extend keep", "Add the feature"])
        #expect(status.commits.map(\.isPushed) == [false, true])
        #expect(try await status.commits.map(\.sha) == git(repo, "log", "-2", "--format=%h").split(separator: "\n").map(String.init))
        #expect(try await status.commits.map(\.date) == git(repo, "log", "-2", "--format=%at").split(separator: "\n").map { Date(timeIntervalSince1970: TimeInterval($0)!) })
    }

    @Test func branchSummaryCountsAgainstTheUpstream() async throws {
        let repo = try await pushedFeatureRepo()
        #expect(await ReviewGit.branchSummary(in: repo.path) == ReviewBranchSummary(branch: "feature", ahead: 1, behind: 0))
        #expect(await ReviewGit.branchSummary(in: root.path) == nil)
    }

    @Test func theDefaultBranchHasNoCommittedCompare() async throws {
        let repo = try await pushedFeatureRepo()
        try await git(repo, "checkout", "--quiet", "-f", "main")
        for text in ["pushed one\n", "pushed two\n"] {
            try write(repo, "keep.txt", text)
            try await git(repo, "commit", "--quiet", "-am", text)
        }
        try await git(repo, "push", "--quiet", "origin", "main")
        try await git(repo, "reset", "--quiet", "--hard", "HEAD~2")
        try write(repo, "keep.txt", "local\n")
        try await git(repo, "commit", "--quiet", "-am", "Local fix")

        let changes = try await ReviewGit.changes(in: repo.path)
        #expect(changes.isDefaultBranch && changes.base == "origin/main")
        #expect(changes.mergeBase == changes.head && changes.committed.isEmpty && changes.total == nil)
        #expect(changes.uncommitted.map(\.path) == ["notes.txt"])

        let status = try await ReviewGit.branchStatus(of: changes)
        #expect(status.ahead == 1 && status.behind == 2)
        #expect(status.upstream == ReviewUpstream(name: "origin/main", ahead: 1, behind: 2))
        #expect(status.commits.map(\.subject) == ["Local fix", "Main moves on"])
        #expect(status.commits.map(\.isPushed) == [false, true])
    }

    @Test func anUpstreamOnAnotherBranchIsTheBaseNotAPushTarget() async throws {
        let repo = try await pushedFeatureRepo()
        try await git(repo, "checkout", "--quiet", "-b", "spike")
        try await git(repo, "commit", "--quiet", "-am", "Spike")
        try await git(repo, "branch", "--quiet", "--set-upstream-to", "origin/main")

        let changes = try await ReviewGit.changes(in: repo.path)
        let status = try await ReviewGit.branchStatus(of: changes)
        #expect(changes.defaultBase == "origin/main" && changes.base == "origin/feature" && changes.baseReason == .nearest)
        #expect(changes.bases.map(\.ref) == ["origin/feature", "feature", "origin/main"])
        #expect(status.upstream == nil)
        #expect(status.commits.map(\.subject) == ["Spike", "Extend keep"])
        #expect(status.commits.allSatisfy { !$0.isPushed })
    }

    @Test func aStackedBranchComparesAgainstTheNearestBranchTowardsMain() async throws {
        let repo = try await repo("stack")
        try await git(repo, "checkout", "--quiet", "-b", "chore/merged")
        try write(repo, "merged.txt", "merged\n")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "Merged chore")
        try await git(repo, "checkout", "--quiet", "main")
        try await git(repo, "merge", "--quiet", "--ff-only", "chore/merged")
        for (branch, names) in [("feat/a", ["a1", "a2"]), ("feat/b", ["b1", "b2", "b3"])] {
            try await git(repo, "checkout", "--quiet", "-b", branch)
            for name in names {
                try write(repo, "\(name).txt", "\(name)\n")
                try await git(repo, "add", ".")
                try await git(repo, "commit", "--quiet", "-m", name)
            }
        }
        try await git(repo, "branch", "feat/diverged", "main")
        try await git(repo, "checkout", "--quiet", "feat/diverged")
        try write(repo, "diverged.txt", "diverged\n")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "--quiet", "-m", "Diverged")
        try await git(repo, "checkout", "--quiet", "feat/b")
        try await git(repo, "update-ref", "refs/remotes/origin/feat/b", "feat/b~1")
        try await git(repo, "update-ref", "refs/remotes/origin/HEAD", "feat/b~1")

        let nearest = try await ReviewGit.changes(in: repo.path)
        #expect(nearest.bases == [ReviewBase(ref: "feat/a", distance: 3), ReviewBase(ref: "main", distance: 5)])
        #expect(nearest.defaultBase == "main" && nearest.base == "feat/a" && nearest.baseReason == .nearest)
        #expect(nearest.committed.map(\.path) == ["b1.txt", "b2.txt", "b3.txt"])
        #expect(try await ReviewGit.branchStatus(of: nearest).commits.map(\.subject) == ["b3", "b2", "b1"])

        let picked = try await ReviewGit.changes(in: repo.path) { _, _ in ("main", "feat/a") }
        #expect(picked.base == "main" && picked.baseReason == .picked && picked.bases == nearest.bases)
        #expect(picked.committed.map(\.path) == ["a1.txt", "a2.txt", "b1.txt", "b2.txt", "b3.txt"])
        #expect(try await ReviewGit.branchStatus(of: picked).ahead == 5)

        let pullRequest = try await ReviewGit.changes(in: repo.path) { root, branch in (root == repo.path && branch == "feat/b" ? "missing" : nil, "feat/a") }
        #expect(pullRequest.base == "feat/a" && pullRequest.baseReason == .pullRequest)

        try await git(repo, "update-ref", "refs/remotes/origin/feat/a", "feat/a")
        try await git(repo, "update-ref", "refs/remotes/origin/feat/a", "feat/a~1")
        let originFirst = try await ReviewGit.changes(in: repo.path)
        #expect(originFirst.bases.map(\.ref) == ["origin/feat/a", "feat/a", "main"] && originFirst.base == "origin/feat/a" && originFirst.baseReason == .nearest)
        try await git(repo, "update-ref", "refs/remotes/origin/feat/a", "feat/a")

        let twins = try await ReviewGit.changes(in: repo.path) { _, _ in (nil, "feat/a") }
        #expect(twins.bases.map(\.ref) == ["origin/feat/a", "main"] && twins.base == "origin/feat/a" && twins.baseReason == .pullRequest)

        try await git(repo, "config", "branch.feat/b.gh-merge-base", "feat/a")
        let configured = try await ReviewGit.changes(in: repo.path)
        #expect(configured.bases.map(\.ref) == ["origin/feat/a", "main"] && configured.base == "origin/feat/a" && configured.baseReason == .configured)
    }

    @Test func withoutABaseChangesAreOnlyUncommitted() async throws {
        let repo = try await repo("trunk")
        try await git(repo, "branch", "-m", "trunk")
        try write(repo, "keep.txt", "changed\n")
        try await git(repo, "commit", "--quiet", "-am", "Second")
        try write(repo, "keep.txt", "again\n")

        let changes = try await ReviewGit.changes(in: repo.path)
        let status = try await ReviewGit.branchStatus(of: changes)
        #expect(changes.base == nil && !changes.isDefaultBranch && changes.committed.isEmpty && changes.total == nil)
        #expect(changes.uncommitted.map(\.path) == ["keep.txt"])
        #expect(status.ahead == 0 && status.behind == 0 && status.upstream == nil)
        #expect(status.commits.map(\.subject) == ["Second", "init"])
    }

    @Test func changesClassifyFoldersGitCannotRead() async throws {
        let plain = root.appending(path: "plain")
        let broken = root.appending(path: "broken")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try write(broken, ".git", "not a gitfile\n")

        await #expect(throws: ReviewGitError.notARepository) { try await ReviewGit.changes(in: plain.path) }
        await #expect(throws: ReviewGitError.folderNotFound) { try await ReviewGit.changes(in: self.root.appending(path: "missing").path) }
        let error = await #expect(throws: ReviewGitError.self) { try await ReviewGit.changes(in: broken.path) }
        guard case .git = error else { Issue.record("expected a git error, got \(String(describing: error))"); return }
    }

    @Test func aRepositoryWithoutCommitsListsItsFilesAsUncommitted() async throws {
        let repo = root.appending(path: "unborn")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(repo, "init", "--quiet", "-b", "main")
        try write(repo, "notes.txt", "one\n")

        let changes = try await ReviewGit.changes(in: repo.path)
        #expect(changes.branch == "main" && changes.committed.isEmpty)
        #expect(changes.uncommitted.map(\.path) == ["notes.txt"])
    }

    @Test func filesListTrackedAndUntrackedButNotIgnoredOrDeleted() async throws {
        let repo = try await repo("files")
        try FileManager.default.createDirectory(at: repo.appending(path: "src/ui"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appending(path: "vendor/lib"), withIntermediateDirectories: true)
        try write(repo, "src/ui/View.swift", "view\n")
        try write(repo, "src/main.swift", "main\n")
        try write(repo, "debug.log", "ignored\n")
        try FileManager.default.removeItem(at: repo.appending(path: "gone.txt"))
        try await git(repo.appending(path: "vendor/lib"), "init", "--quiet")

        let files = try await ReviewGit.files(in: repo.path)
        #expect(files == [".gitignore", "keep.txt", "old.txt", "src/main.swift", "src/ui/View.swift"])

        let tree = ReviewFileTree.nodes(files)
        #expect(tree.map(\.path) == ["src", ".gitignore", "keep.txt", "old.txt"])
        #expect(tree.first?.children?.map(\.path) == ["src/ui", "src/main.swift"])
        #expect(tree.first?.children?.first?.children?.map(\.name) == ["View.swift"])
        #expect(tree.dropFirst().allSatisfy { $0.children == nil })
    }

    @Test func unreachableOriginStillComparesExistingRefs() async throws {
        let repo = try await repo("offline")
        try await git(repo, "update-ref", "refs/remotes/origin/main", "main")
        try await git(repo, "remote", "add", "origin", root.appending(path: "missing.git").path)
        try await git(repo, "checkout", "--quiet", "-b", "feature")
        try write(repo, "keep.txt", "changed\n")

        let changes = try await ReviewGit.changes(in: repo.path)
        #expect(changes.base == "origin/main")
        #expect(changes.fetchedAt == nil)
        #expect(changes.fetchError?.contains("missing.git") == true)
        #expect(changes.uncommitted.map(\.path) == ["keep.txt"])
    }

    @Test func pullRequestFilesUseItsMergeBaseWithoutUpdatingTheCheckout() async throws {
        let producer = try await repo("producer")
        let fork = try await git(producer, "rev-parse", "HEAD")
        try await git(producer, "checkout", "--quiet", "-b", "release")
        try write(producer, "keep.txt", "one\ntwo\nrelease\n")
        try await git(producer, "commit", "--quiet", "-am", "Release base")
        let release = try await git(producer, "rev-parse", "HEAD")
        try await git(producer, "checkout", "--quiet", "-b", "pr-fixture")
        try write(producer, "keep.txt", "one\ntwo\nrelease\nproposed\n")
        try await git(producer, "mv", "old.txt", "renamed.txt")
        try await git(producer, "commit", "--quiet", "-am", "Proposed changes")
        let head = try await git(producer, "rev-parse", "HEAD")
        try await git(producer, "checkout", "--quiet", "main")
        try write(producer, "keep.txt", "one\ntwo\nmain\n")
        try await git(producer, "commit", "--quiet", "-am", "Main advances")

        let origin = root.appending(path: "Acme/Billing.git")
        try FileManager.default.createDirectory(at: origin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(root, "clone", "--quiet", "--bare", producer.path, origin.path)
        try await git(origin, "update-ref", "refs/pull/7/head", head)
        try await git(origin, "branch", "-D", "pr-fixture")
        let checkout = root.appending(path: "checkout")
        try await git(root, "clone", "--quiet", "--no-local", origin.path, checkout.path)
        let github = "https://github.com/Acme/Billing.git"
        try await git(checkout, "config", "remote.origin.url", github)
        try await git(checkout, "config", "url.\(origin.path).insteadOf", github)
        try await git(checkout, "config", "--add", "remote.origin.fetch", "+refs/pull/*:refs/remotes/origin/pull/*")
        try write(checkout, "keep.txt", "staged\n")
        try await git(checkout, "add", "keep.txt")
        try write(checkout, "keep.txt", "working copy\n")
        let changes = try await ReviewGit.changes(in: checkout.path)
        let refs = try await git(checkout, "show-ref", "--head")
        let index = try await git(checkout, "ls-files", "--stage")

        let result = try await ReviewGit.pullRequestFiles(number: 7, repository: "acme/billing", base: "release", in: checkout.path)
        let modified = ReviewFile(path: "keep.txt", oldPath: nil, status: .modified, additions: 1, deletions: 0)
        let renamed = ReviewFile(path: "renamed.txt", oldPath: "old.txt", status: .renamed, additions: 0, deletions: 0)
        #expect(result.base == release && result.head == head)
        #expect(result.files == [modified, renamed])
        let compare = ReviewCompare.range(base: result.base, head: result.head)
        #expect(compare.isHistorical)
        #expect(try await ReviewGit.contents(of: modified, compare: compare, in: changes) == ReviewContents(original: .text("one\ntwo\nrelease\n"), modified: .text("one\ntwo\nrelease\nproposed\n")))
        let renamedText = ReviewText.text("a\nb\nc\nd\ne\nf\n")
        #expect(try await ReviewGit.contents(of: renamed, compare: compare, in: changes) == ReviewContents(original: renamedText, modified: renamedText))
        #expect(try await git(checkout, "show-ref", "--head") == refs)
        #expect(try await git(checkout, "ls-files", "--stage") == index)
        #expect(try ReviewGit.workingTreeText("keep.txt", in: checkout.path) == .text("working copy\n"))

        try await git(checkout, "update-ref", "-d", "refs/remotes/origin/release")
        let refsWithoutRelease = try await git(checkout, "show-ref", "--head")
        let fetchedBase = try await ReviewGit.pullRequestFiles(number: 7, repository: "acme/billing", base: "release", in: checkout.path)
        #expect(fetchedBase.base == release && fetchedBase.files == [modified, renamed])
        #expect(try await git(checkout, "show-ref", "--head") == refsWithoutRelease)

        let fallback = try await ReviewGit.pullRequestFiles(number: 7, repository: "acme/billing", base: "missing", in: checkout.path)
        #expect(fallback.base == fork && fallback.head == head)
        #expect(fallback.files.first?.additions == 2)
        await #expect(throws: ReviewGitError.git(arguments: ["config", "--get", "remote.origin.url"], message: "Origin does not point to acme/other.")) {
            try await ReviewGit.pullRequestFiles(number: 7, repository: "acme/other", base: nil, in: checkout.path)
        }
        await #expect(throws: ReviewGitError.git(arguments: ["rev-parse", "HEAD"], message: "Invalid commit SHA")) {
            try await ReviewGit.contents(of: modified, compare: .range(base: fork, head: "HEAD"), in: changes)
        }
    }

    @Test func hungFetchIsKilledAfterTheTimeout() async throws {
        let repo = try await repo("hung")
        let ssh = root.appending(path: "fake-ssh")
        try "#!/bin/sh\nsleep 30\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        try await git(repo, "config", "core.sshCommand", ssh.path)
        try await git(repo, "remote", "add", "origin", "ssh://example.invalid/berth.git")

        let start = Date.now
        await #expect(throws: ReviewGitError.git(arguments: ["fetch", "origin"], message: "timed out after 1 s")) {
            try await ReviewGit.git(["fetch", "origin"], in: repo.path, timeout: 1)
        }
        #expect(Date.now.timeIntervalSince(start) < 5)
    }

    @Test func workingTreeTextStaysInsideTheRepository() async throws {
        let repo = try await repo("tree")
        #expect(try ReviewGit.workingTreeText("keep.txt", in: repo.path) == .text("one\ntwo\n"))
        #expect(throws: ReviewGitError.pathOutsideRoot("../keep.txt")) { try ReviewGit.workingTreeText("../keep.txt", in: repo.path) }
    }

    @Test func saveStaysInsideTheRepository() async throws {
        let repo = try await repo("save")
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write(outside, "target.txt", "secret\n")
        try FileManager.default.createSymbolicLink(at: repo.appending(path: "escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: repo.appending(path: "link.txt"), withDestinationURL: outside.appending(path: "target.txt"))
        try FileManager.default.createSymbolicLink(at: repo.appending(path: "hooks"), withDestinationURL: repo.appending(path: ".git/hooks"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.appending(path: "keep.txt").path)

        try ReviewGit.save("edited\n", to: "keep.txt", in: repo.path)
        #expect(try String(contentsOf: repo.appending(path: "keep.txt"), encoding: .utf8) == "edited\n")
        #expect(try FileManager.default.attributesOfItem(atPath: repo.appending(path: "keep.txt").path)[.posixPermissions] as? Int == 0o755)

        for path in ["../x", "/tmp/berth-x", "", "a//b", "./keep.txt", ".git/config", ".GIT/config", "escape/target.txt", "escape/new.txt", "link.txt", "hooks/pre-commit", "missing/new.txt"] {
            #expect(throws: ReviewGitError.pathOutsideRoot(path)) { try ReviewGit.save("pwned\n", to: path, in: repo.path) }
        }
        #expect(try String(contentsOf: outside.appending(path: "target.txt"), encoding: .utf8) == "secret\n")
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "new.txt").path))
    }

    @Test func commentPromptDropsControlCharacters() {
        let comment = ReviewComment(id: "c", path: "a.swift", line: 2, endLine: 3, text: "fix\u{1B}[2J this\r\n\tnow\u{7F}", snippet: "let a = 1\u{0}\n\tlet b = 2\u{3}")
        #expect(ReviewComment.prompt(for: [comment], branch: "feature", base: "main") == "Review comments on feature (vs main):\n\na.swift:2-3\n```swift\nlet a = 1\n\tlet b = 2\n```\nfix[2J this\n\tnow")
    }

    @Test func commentPromptMarksCommittedLineNumbers() {
        let committed = ReviewComment(id: "c", path: "a.swift", line: 4, endLine: 4, text: "rename", snippet: "let b = 2", compare: .committed)
        let file = ReviewComment(id: "f", path: "b.swift", line: 1, endLine: 1, text: "ok", snippet: "x", compare: nil)
        #expect(ReviewComment.prompt(for: [committed, file], branch: "feature", base: "main") == "Review comments on feature (vs main):\n\na.swift:4 (as committed)\n```swift\nlet b = 2\n```\nrename\n\nb.swift:1\n```swift\nx\n```\nok")
    }
}
