import BerthCore
import Foundation
import Testing

struct RemoteChangesTests {
    @Test func changesMessagesRoundTrip() throws {
        let request = RemoteClientMessage.changes(sessionID: "s")
        guard case let .changes(sessionID) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(request)) else { throw CancellationError() }

        #expect(sessionID == "s")

        let diffRequest = RemoteClientMessage.changeDiff(sessionID: "s", path: "a/b.swift", isCommitted: true)
        guard case let .changeDiff(_, path, isCommitted) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(diffRequest)) else { throw CancellationError() }

        #expect(path == "a/b.swift" && isCommitted)

        let file = RemoteChangedFile(path: "a.swift", oldPath: nil, status: "M", additions: 2, deletions: 1)
        let changes = RemoteChanges(branch: "main", base: nil, uncommitted: [file], committed: [], isTruncated: false)
        guard case let .changes(_, decoded) = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(RemoteServerMessage.changes(sessionID: "s", changes: changes))) else { throw CancellationError() }

        #expect(decoded == changes)

        let diff = RemoteFileDiff(lines: [RemoteDiffLine(kind: .added, old: nil, new: 1, text: "x")], isBinary: false, isTruncated: true)
        guard case let .changeDiff(_, _, _, decodedDiff) = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(RemoteServerMessage.changeDiff(sessionID: "s", path: "a", isCommitted: false, diff: diff))) else { throw CancellationError() }

        #expect(decodedDiff == diff)
    }

    @Test func unifiedDiffNumbersLinesAndKeepsThreeLinesOfContext() {
        let old = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacing("line 6\n", with: "six\nsix and a half\n")
        let diff = RemoteFileDiff(ReviewContents(original: .text(old), modified: .text(new)))

        #expect(diff.lines.first == RemoteDiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -3,7 +3,8 @@"))
        #expect(diff.lines.filter { $0.kind == .removed }.map(\.old) == [6])
        #expect(diff.lines.filter { $0.kind == .added }.map(\.new) == [6, 7])
        #expect(diff.lines.filter { $0.kind == .context }.map(\.new) == [3, 4, 5, 8, 9, 10])
        #expect(diff.lines.count == 1 + 6 + 1 + 2)
    }

    @Test func distantChangesMakeSeparateHunksAndAddedFilesAreAllAdditions() {
        let lines = (1...30).map(String.init)
        var changed = lines
        changed[1] = "two"
        changed[28] = "twenty-nine"
        let diff = RemoteFileDiff(ReviewContents(original: .text(lines.joined(separator: "\n")), modified: .text(changed.joined(separator: "\n"))))
        #expect(diff.lines.count { $0.kind == .hunk } == 2)

        let added = RemoteFileDiff(ReviewContents(original: nil, modified: .text("a\nb\n")))
        #expect(added.lines == [RemoteDiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -0,0 +1,2 @@"), RemoteDiffLine(kind: .added, old: nil, new: 1, text: "a"), RemoteDiffLine(kind: .added, old: nil, new: 2, text: "b")])
    }

    @Test func binaryAndOversizedFilesCarryNoLinesAndLongDiffsTruncate() {
        #expect(RemoteFileDiff(ReviewContents(original: .text("a"), modified: .binary)) == RemoteFileDiff(lines: [], isBinary: true, isTruncated: false))
        #expect(RemoteFileDiff(ReviewContents(original: .tooLarge(bytes: 9_000_000), modified: .text("a"))) == RemoteFileDiff(lines: [], isBinary: false, isTruncated: true))

        let long = (1...100).map { _ in String(repeating: "x", count: 100) }.joined(separator: "\n")
        let truncated = RemoteFileDiff(ReviewContents(original: nil, modified: .text(long)), maxBytes: 1000)
        #expect(truncated.isTruncated && truncated.lines.count < 20)
    }
}
