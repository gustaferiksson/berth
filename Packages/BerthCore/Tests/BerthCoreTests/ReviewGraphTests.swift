@testable import BerthCore
import Foundation
import Testing

struct ReviewGraphTests {
    @Test func linearHistoryUsesOneLane() {
        let rows = ReviewGraph.layout([commit("c", ["b"]), commit("b", ["a"]), commit("a")])
        #expect(rows.map(\.sha) == ["c", "b", "a"])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(rows.map(\.laneCount) == [1, 1, 1])
        #expect(rows.map(\.entersFromAbove) == [false, true, true])
        #expect(rows.map(\.parentLanes) == [[0], [0], []])
        #expect(rows.allSatisfy { $0.through.isEmpty && $0.merges.isEmpty })
    }

    @Test func branchesJoinAnExistingLaneAndLeaveSlotsForLaterBranches() {
        let commits = [
            commit("merge", ["main", "side"]),
            commit("side", ["base"]),
            commit("main", ["base", "other"]),
            commit("standalone"),
            commit("other", ["base"]),
            commit("base"),
        ]
        let rows = ReviewGraph.layout(commits)
        #expect(rows.map(\.lane) == [0, 1, 0, 0, 2, 1])
        #expect(rows.map(\.laneCount) == [2, 2, 3, 3, 3, 2])
        #expect(rows.map(\.through) == [[], [0], [1], [1, 2], [1], []])
        #expect(rows.map(\.parentLanes) == [[0, 1], [1], [1, 2], [], [1], []])
        #expect(rows.map(\.entersFromAbove) == [false, true, true, false, true, true])

        for length in 0...commits.count {
            #expect(ReviewGraph.layout(Array(commits.prefix(length))) == Array(rows.prefix(length)))
        }
    }

    @Test func octopusMergeReusesACompletedBranchLane() {
        let rows = ReviewGraph.layout([
            commit("merge", ["a", "b", "c", "d"]),
            commit("b"),
            commit("e", ["f"]),
            commit("c", ["f"]),
            commit("f"),
            commit("d"),
            commit("a"),
        ])
        #expect(rows[0].parentLanes == [0, 1, 2, 3])
        #expect(rows[0].laneCount == 4)
        #expect(rows[1].through == [0, 2, 3])
        #expect(rows[2].lane == 1 && !rows[2].entersFromAbove)
        #expect(rows[3].parentLanes == [1] && rows[3].through == [0, 1, 3])
        #expect(rows[6].laneCount == 1)
    }

    @Test func independentRootsEachStartWithoutAnIncomingLine() {
        let rows = ReviewGraph.layout([commit("a"), commit("b")])
        #expect(rows.map(\.lane) == [0, 0])
        #expect(rows.allSatisfy { !$0.entersFromAbove && $0.parentLanes.isEmpty })
    }

    @Test func parserHandlesDecorationsAndDetachedHead() throws {
        let record = Data(["sha", "first second", "Ada", "1700000000", "HEAD -> main, topic, origin/main, tag: v1.0, origin/HEAD", "Subject"].joined(separator: "\u{1f}").utf8)
        let parsed = try #require(GraphCommit.parse(record))
        #expect(parsed == GraphCommit(
            sha: "sha", parents: ["first", "second"], author: "Ada", date: Date(timeIntervalSince1970: 1_700_000_000),
            refs: [GraphRef(name: "main", kind: .head), GraphRef(name: "topic", kind: .branch), GraphRef(name: "origin/main", kind: .remote), GraphRef(name: "v1.0", kind: .tag)],
            subject: "Subject"
        ))
        let detached = Data(["sha", "", "Ada", "1700000000", "HEAD", ""].joined(separator: "\u{1f}").utf8)
        #expect(GraphCommit.parse(detached)?.refs == [GraphRef(name: "HEAD", kind: .head)])
        #expect(GraphCommit.parse(detached)?.parents.isEmpty == true)
        #expect(GraphCommit.parse(Data("bad record".utf8)) == nil)
    }

    @Test func gitHistoryPagesAndDiffsAgainstFirstParent() async throws {
        ReviewGitTests.isolatedGitConfig
        let repo = FileManager.default.temporaryDirectory.appending(path: "berth-graph-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        @discardableResult
        func git(_ arguments: String...) async throws -> String {
            try await String(decoding: ReviewGit.git(arguments, in: repo.path), as: UTF8.self).trimmingCharacters(in: .newlines)
        }

        try await git("init", "--quiet", "-b", "main")
        #expect(try await ReviewGit.graph(in: repo.path, skip: 0, limit: 2).isEmpty)
        try "one\ntwo\n".write(to: repo.appending(path: "old.txt"), atomically: true, encoding: .utf8)
        try await git("add", ".")
        try await git("commit", "--quiet", "-m", "Root")
        let root = try await git("rev-parse", "HEAD")
        try await git("tag", "v1.0")
        try await git("checkout", "--quiet", "-b", "topic/side")
        try "side\n".write(to: repo.appending(path: "side.txt"), atomically: true, encoding: .utf8)
        try await git("add", ".")
        try await git("commit", "--quiet", "-m", "Add side")
        let side = try await git("rev-parse", "HEAD")
        try await git("update-ref", "refs/remotes/upstream/side", side)
        try await git("symbolic-ref", "refs/remotes/upstream/HEAD", "refs/remotes/upstream/side")

        try await git("checkout", "--quiet", "main")
        try await git("mv", "old.txt", "renamed.txt")
        try await git("commit", "--quiet", "-m", "Rename")
        let rename = try await git("rev-parse", "HEAD")
        try await git("merge", "--quiet", "--no-ff", "-m", "Merge", "topic/side")
        let merge = try await git("rev-parse", "HEAD")

        let full = try await ReviewGit.graph(in: repo.path, skip: 0, limit: 10)
        let first = try await ReviewGit.graph(in: repo.path, skip: 0, limit: 2)
        let second = try await ReviewGit.graph(in: repo.path, skip: 2, limit: 2)
        #expect(first.count == 2 && second.count == 2 && first + second == full)
        #expect(try await ReviewGit.graph(in: repo.path, skip: 4, limit: 2).isEmpty)
        #expect(full.first?.sha == merge && full.last?.sha == root)
        #expect(full.first?.parents == [rename, side])
        #expect(full.first?.refs == [GraphRef(name: "main", kind: .head)])
        #expect(full.last?.refs == [GraphRef(name: "v1.0", kind: .tag)])
        #expect(Set(full.first { $0.sha == side }?.refs ?? []) == [GraphRef(name: "topic/side", kind: .branch), GraphRef(name: "upstream/side", kind: .remote)])

        let created = ReviewFile(path: "old.txt", oldPath: nil, status: .added, additions: 2, deletions: 0)
        let added = ReviewFile(path: "side.txt", oldPath: nil, status: .added, additions: 1, deletions: 0)
        let renamed = ReviewFile(path: "renamed.txt", oldPath: "old.txt", status: .renamed, additions: 0, deletions: 0)
        #expect(try await ReviewGit.commitFiles(root, in: repo.path) == [created])
        #expect(try await ReviewGit.commitFiles(side, in: repo.path) == [added])
        #expect(try await ReviewGit.commitFiles(String(rename.prefix(7)), in: repo.path) == [renamed])
        #expect(try await ReviewGit.commitFiles(merge, in: repo.path) == [added])
        await #expect(throws: ReviewGitError.git(arguments: ["rev-parse", "HEAD^"], message: "Invalid commit SHA")) {
            try await ReviewGit.commitFiles("HEAD^", in: repo.path)
        }

        try "working copy\n".write(to: repo.appending(path: "renamed.txt"), atomically: true, encoding: .utf8)
        let changes = try await ReviewGit.changes(in: repo.path)
        #expect(try await ReviewGit.contents(of: created, compare: .commit(root), in: changes) == ReviewContents(original: nil, modified: .text("one\ntwo\n")))
        #expect(try await ReviewGit.contents(of: renamed, compare: .commit(rename), in: changes) == ReviewContents(original: .text("one\ntwo\n"), modified: .text("one\ntwo\n")))
    }

    private func commit(_ sha: String, _ parents: [String] = []) -> GraphCommit {
        GraphCommit(sha: sha, parents: parents, author: "", date: .distantPast, refs: [], subject: "")
    }
}
