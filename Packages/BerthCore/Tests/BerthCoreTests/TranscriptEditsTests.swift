@testable import BerthCore
import Foundation
import Testing

struct TranscriptEditsTests {
    private let home = FileManager.default.temporaryDirectory.appending(path: "berth-edits-\(UUID().uuidString)").resolvingSymlinksInPath()

    private func folder(_ path: String, marker: String? = nil) throws -> String {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let marker { try marker.write(to: url.appending(path: ".git"), atomically: true, encoding: .utf8) } else { try FileManager.default.createDirectory(at: url.appending(path: ".git"), withIntermediateDirectories: true) }
        return url.path
    }

    private func edit(_ tool: String, _ key: String, _ path: String, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"tu","name":"\#(tool)","input":{"\#(key)":"\#(path)"}}]}}"#
    }

    @Test func resolvesEditedFilesToTheirRepositories() throws {
        let billing = try folder("billing")
        let web = try folder("web")
        let infra = try folder("infra")
        let linked = try folder("infra-linked", marker: "gitdir: \(infra)/.git/worktrees/linked\n")
        try FileManager.default.createDirectory(atPath: infra + "/.git/worktrees/linked", withIntermediateDirectories: true)
        try "../..\n".write(toFile: infra + "/.git/worktrees/linked/commondir", atomically: true, encoding: .utf8)
        let side = try folder("side")
        let loose = try folder("notes")
        try FileManager.default.removeItem(atPath: loose + "/.git")
        let lines = [
            edit("Edit", "file_path", billing + "/src/a.swift"),
            edit("Write", "file_path", web + "/src/new/b.ts"),
            edit("MultiEdit", "file_path", linked + "/ci.yml"),
            edit("NotebookEdit", "notebook_path", billing + "/n.ipynb"),
            edit("Read", "file_path", home.path + "/read-only/c.swift"),
            edit("Edit", "file_path", loose + "/loose.md"),
            edit("Edit", "file_path", "relative/d.swift"),
            edit("Edit", "file_path", side + "/ignored.swift", sidechain: true),
        ]
        let url = home.appending(path: "session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        var edits = TranscriptEdits()
        edits.read(url)
        #expect(edits.repositories == [billing: billing, web: web, infra: linked])

        let late = try folder("late")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((edit("Edit", "file_path", late + "/e.swift") + "\n").utf8))
        try handle.close()
        edits.read(url)
        #expect(Set(edits.repositories.keys) == [billing, web, infra, late])
    }
}
