@testable import BerthCore
import Foundation
import Testing

struct ReviewEditBufferTests {
    private func temporaryFile(_ text: String) throws -> (root: String, path: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appending(path: "note.md"), atomically: false, encoding: .utf8)
        return (root.path, "note.md")
    }

    private func replaceAtomically(_ text: String, at path: String, in root: String) throws {
        let scratch = URL(filePath: root).appending(path: ".tmp-\(UUID().uuidString)")
        try text.write(to: scratch, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(URL(filePath: root).appending(path: path), withItemAt: scratch)
    }

    private func disk(_ path: String, in root: String) throws -> String {
        guard case let .text(text) = try ReviewGit.workingTreeText(path, in: root) else { throw ReviewGitError.pathOutsideRoot(path) }

        return text
    }

    @Test func cleanBufferFollowsAnAtomicExternalWrite() throws {
        let (root, path) = try temporaryFile("one\n")
        var buffer = try ReviewEditBuffer(base: disk(path, in: root))

        try replaceAtomically("two\n", at: path, in: root)

        #expect(try buffer.read(disk: disk(path, in: root), draft: nil) == .current)
        #expect(buffer.base == "two\n")
        #expect(!buffer.hasConflict)
    }

    @Test func dirtyBufferFlagsAnAtomicExternalWriteAndKeepsTheDraft() throws {
        let (root, path) = try temporaryFile("one\n")
        var buffer = try ReviewEditBuffer(base: disk(path, in: root))

        try replaceAtomically("two\n", at: path, in: root)

        #expect(try buffer.read(disk: disk(path, in: root), draft: "one mine\n") == .conflict)
        #expect(buffer.incoming == "two\n")
        #expect(buffer.base == "one\n")
    }

    @Test func keepingMineMakesTheNextSaveSafe() throws {
        let (root, path) = try temporaryFile("one\n")
        var buffer = try ReviewEditBuffer(base: disk(path, in: root))
        try replaceAtomically("two\n", at: path, in: root)
        _ = try buffer.read(disk: disk(path, in: root), draft: "one mine\n")

        buffer.acceptIncoming()

        #expect(try buffer.read(disk: disk(path, in: root), draft: "one mine\n") == .current)
        #expect(!buffer.hasConflict)
    }

    @Test func aDraftMatchingTheDiskIsNotAConflict() {
        var buffer = ReviewEditBuffer(base: "one\n")

        #expect(buffer.read(disk: "two\n", draft: "two\n") == .current)
        #expect(buffer.base == "two\n")
    }

    @Test func aRevertedDiskClearsTheConflict() {
        var buffer = ReviewEditBuffer(base: "one\n")
        _ = buffer.read(disk: "two\n", draft: "mine\n")

        #expect(buffer.read(disk: "one\n", draft: "mine\n") == .current)
        #expect(!buffer.hasConflict)
    }
}
