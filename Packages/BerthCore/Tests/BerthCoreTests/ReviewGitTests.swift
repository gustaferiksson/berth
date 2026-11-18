import Foundation
import Testing
@testable import BerthCore

final class ReviewGitTests {
    static let isolatedGitConfig: Void = {
        let config = FileManager.default.temporaryDirectory.appending(path: "berth-review-gitconfig-\(UUID().uuidString)")
        try! "[user]\n\tname = Berth Tests\n\temail = tests@example.invalid\n[commit]\n\tgpgsign = false\n".write(to: config, atomically: true, encoding: .utf8)
        setenv("GIT_CONFIG_GLOBAL", config.path, 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    }()

    let root = FileManager.default.temporaryDirectory.appending(path: "berth-review-\(UUID().uuidString)").resolvingSymlinksInPath()

    init() throws {
        Self.isolatedGitConfig
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ repo: URL, _ arguments: String...) async throws -> String {
        String(decoding: try await ReviewGit.git(arguments, in: repo.path), as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func write(_ repo: URL, _ path: String, _ text: String) throws {
        try text.write(to: repo.appending(path: path), atomically: true, encoding: .utf8)
    }

    func repo(_ name: String) async throws -> URL {
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

    func featureRepo() async throws -> URL {
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

    func pushedFeatureRepo() async throws -> URL {
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
        #expect(changes.root == (try await git(repo, "rev-parse", "--show-toplevel")))
        #expect(changes.branch == "feature" && changes.base == "main")
        #expect(changes.mergeBase == (try await git(repo, "rev-parse", "main")))
        #expect(changes.committed.map(\.path) == ["committed.txt", "logo.bin"])
        #expect(changes.uncommitted.map(\.path) == ["gone.txt", "image.bin", "keep.txt", "new.txt", "renamed file.txt"])
        #expect(changes.uncommitted.map(\.status) == [.deleted, .added, .modified, .added, .renamed])
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
            let files = compare == .committed ? changes.committed : changes.uncommitted
            return try await ReviewGit.contents(of: try #require(files.first { $0.path == path }), compare: compare, in: changes)
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
        #expect(changes.root == (try await git(repo, "rev-parse", "--show-toplevel")))
        #expect(changes.branch == "feature" && !changes.isDefaultBranch && changes.base == "origin/main")
        #expect(changes.head == (try await git(repo, "rev-parse", "HEAD")))
        #expect(changes.mergeBase == (try await git(repo, "rev-parse", "main~1")))
        #expect(changes.fetchedAt != nil && changes.fetchError == nil)

        #expect(changes.uncommitted.map(\.path) == ["gone.txt", "keep.txt", "notes.txt"])
        #expect(changes.uncommitted.map(\.status) == [.deleted, .modified, .added])
        #expect(changes.uncommitted.map { [$0.additions, $0.deletions] } == [[0, 1], [1, 0], [1, 0]])
        #expect(changes.committed.map(\.path) == ["feature.txt", "keep.txt"])
        #expect(changes.committed.map(\.status) == [.added, .modified])
        #expect(changes.committed.map { [$0.additions, $0.deletions] } == [[1, 0], [1, 0]])
    }

    @Test func contentsFollowTheirCompareAndTheListedHead() async throws {
        let repo = try await pushedFeatureRepo()
        let changes = try await ReviewGit.changes(in: repo.path)
        try await git(repo, "commit", "--quiet", "-am", "Later work")
        let contents = { (path: String, compare: ReviewCompare) in
            let files = compare == .committed ? changes.committed : changes.uncommitted
            return try await ReviewGit.contents(of: try #require(files.first { $0.path == path }), compare: compare, in: changes)
        }

        #expect(try await contents("keep.txt", .committed) == ReviewContents(original: .text("one\ntwo\n"), modified: .text("one\ntwo\nthree\n")))
        #expect(try await contents("feature.txt", .committed) == ReviewContents(original: nil, modified: .text("first\n")))
        #expect(try await contents("keep.txt", .uncommitted) == ReviewContents(original: .text("one\ntwo\nthree\n"), modified: .text("one\ntwo\nthree\nfour\n")))
        #expect(try await contents("gone.txt", .uncommitted) == ReviewContents(original: .text("bye\n"), modified: nil))
        #expect(try await contents("notes.txt", .uncommitted) == ReviewContents(original: nil, modified: .text("draft\n")))
    }

    @Test func branchStatusCountsAgainstTheBaseAndTheUpstream() async throws {
        let repo = try await pushedFeatureRepo()
        let status = try await ReviewGit.branchStatus(of: try await ReviewGit.changes(in: repo.path))
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.upstream == ReviewUpstream(name: "origin/feature", ahead: 1, behind: 0))
        #expect(status.commits.map(\.subject) == ["Extend keep", "Add the feature"])
        #expect(status.commits.map(\.isPushed) == [false, true])
        #expect(status.commits.map(\.sha) == (try await git(repo, "log", "-2", "--format=%h")).split(separator: "\n").map(String.init))
        #expect(status.commits.map(\.date) == (try await git(repo, "log", "-2", "--format=%at")).split(separator: "\n").map { Date(timeIntervalSince1970: TimeInterval($0)!) })
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
        #expect(changes.mergeBase == changes.head && changes.committed.isEmpty)
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
        #expect(changes.base == "origin/main")
        #expect(status.upstream == nil)
        #expect(status.commits.map(\.subject) == ["Spike", "Extend keep", "Add the feature"])
        #expect(status.commits.allSatisfy { !$0.isPushed })
    }

    @Test func withoutABaseChangesAreOnlyUncommitted() async throws {
        let repo = try await repo("trunk")
        try await git(repo, "branch", "-m", "trunk")
        try write(repo, "keep.txt", "changed\n")
        try await git(repo, "commit", "--quiet", "-am", "Second")
        try write(repo, "keep.txt", "again\n")

        let changes = try await ReviewGit.changes(in: repo.path)
        let status = try await ReviewGit.branchStatus(of: changes)
        #expect(changes.base == nil && !changes.isDefaultBranch && changes.committed.isEmpty)
        #expect(changes.uncommitted.map(\.path) == ["keep.txt"])
        #expect(status.ahead == 0 && status.behind == 0 && status.upstream == nil)
        #expect(status.commits.map(\.subject) == ["Second", "init"])
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
