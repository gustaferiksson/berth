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

    @Test func snapshotIncludesCommittedUncommittedAndUntrackedWork() async throws {
        let repo = try await featureRepo()
        try FileManager.default.createDirectory(at: repo.appending(path: "empty"), withIntermediateDirectories: true)
        let all = try await ReviewGit.snapshot(in: repo.appending(path: "empty").path)
        #expect(all.root == (try await git(repo, "rev-parse", "--show-toplevel")))
        #expect(all.branch == "feature")
        #expect(all.base == "main")
        #expect(all.mergeBase == (try await git(repo, "rev-parse", "main")))
        #expect(all.files.map(\.path) == ["committed.txt", "gone.txt", "image.bin", "keep.txt", "logo.bin", "new.txt", "renamed file.txt"])
        #expect(all.files.map(\.status) == [.added, .deleted, .added, .modified, .added, .added, .renamed])
        #expect(all.files.first { $0.path == "renamed file.txt" }?.oldPath == "old.txt")
        #expect(all.files.first { $0.path == "keep.txt" }.map { [$0.additions, $0.deletions] } == [1, 0])
        #expect(all.files.first { $0.path == "new.txt" }.map { [$0.additions, $0.deletions] } == [2, 0])
        #expect(all.files.first { $0.path == "logo.bin" }.map { [$0.additions, $0.deletions] } == [nil, nil])
        #expect(all.files.first { $0.path == "image.bin" }?.additions == nil)
        #expect(all.fetchedAt == nil && all.fetchError == nil)
    }

    @Test func withoutABaseTheSnapshotShowsUncommittedWork() async throws {
        let repo = try await repo("baseless")
        try await git(repo, "branch", "-m", "trunk")
        try write(repo, "keep.txt", "changed\n")

        let snapshot = try await ReviewGit.snapshot(in: repo.path)
        #expect(snapshot.base == "HEAD")
        #expect(snapshot.mergeBase == (try await git(repo, "rev-parse", "HEAD")))
        #expect(snapshot.files.map(\.path) == ["keep.txt"])
    }

    @Test func contentsForEachSide() async throws {
        let repo = try await featureRepo()
        try Data(repeating: 65, count: 3 * 1024 * 1024).write(to: repo.appending(path: "huge.txt"))
        let snapshot = try await ReviewGit.snapshot(in: repo.path)
        let file = { (path: String) in try #require(snapshot.files.first { $0.path == path }) }

        #expect(try await ReviewGit.contents(of: file("new.txt"), in: snapshot) == ReviewContents(original: nil, modified: .text("a\nb")))
        #expect(try await ReviewGit.contents(of: file("gone.txt"), in: snapshot) == ReviewContents(original: .text("bye\n"), modified: nil))
        #expect(try await ReviewGit.contents(of: file("keep.txt"), in: snapshot) == ReviewContents(original: .text("one\ntwo\n"), modified: .text("one\ntwo\nthree\n")))
        #expect(try await ReviewGit.contents(of: file("renamed file.txt"), in: snapshot) == ReviewContents(original: .text("a\nb\nc\nd\ne\nf\n"), modified: .text("a\nb\nc\nd\ne\nf\n")))
        #expect(try await ReviewGit.contents(of: file("logo.bin"), in: snapshot) == ReviewContents(original: nil, modified: .binary))
        #expect(try await ReviewGit.contents(of: file("huge.txt"), in: snapshot) == ReviewContents(original: nil, modified: .tooLarge(bytes: 3 * 1024 * 1024)))
    }

    @Test func unreachableOriginStillComparesExistingRefs() async throws {
        let repo = try await repo("offline")
        try await git(repo, "update-ref", "refs/remotes/origin/main", "main")
        try await git(repo, "remote", "add", "origin", root.appending(path: "missing.git").path)
        try await git(repo, "checkout", "--quiet", "-b", "feature")
        try write(repo, "keep.txt", "changed\n")

        let snapshot = try await ReviewGit.snapshot(in: repo.path)
        #expect(snapshot.base == "origin/main")
        #expect(snapshot.fetchedAt == nil)
        #expect(snapshot.fetchError?.contains("missing.git") == true)
        #expect(snapshot.files.map(\.path) == ["keep.txt"])
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
}
