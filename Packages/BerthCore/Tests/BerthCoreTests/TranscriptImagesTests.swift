@testable import BerthCore
import Foundation
import Testing

struct TranscriptImagesTests {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    private func transcript(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "images-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func isJPEG(_ data: Data?) -> Bool {
        data?.prefix(2) == Data([0xFF, 0xD8])
    }

    private var screenshotLines: [String] {
        [
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/shots/home.png"}}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"ok"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}]}}"#,
        ]
    }

    @Test func listsImageReferencesWithoutTheBytes() {
        let parsed = TranscriptTail.entries(in: Data((screenshotLines.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: [])
        let result = parsed.entries[1]
        #expect(result.kind == .toolResult && result.text == "ok")
        #expect(result.imageRefs == [RemoteImageRef(id: "u1-0-0", bytes: png.utf8.count * 3 / 4)])
        #expect(parsed.entries[0].imageRefs == nil)
    }

    @Test func servesBothVariantsAsJPEG() throws {
        let url = try transcript(screenshotLines)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(isJPEG(TranscriptImages.image(id: "u1-0-0", variant: .thumbnail, in: url)))
        #expect(isJPEG(TranscriptImages.image(id: "u1-0-0", variant: .full, in: url)))
    }

    @Test func servesFromTheLineTheTailReaderFound() throws {
        let url = try transcript(screenshotLines)
        defer { try? FileManager.default.removeItem(at: url) }

        let chunk = try #require(TranscriptTail.read(url, after: nil))
        let line = try #require(chunk.imageLines["u1-0-0"])
        #expect(isJPEG(TranscriptImages.image(id: "u1-0-0", variant: .full, in: url, line: line)))
        #expect(TranscriptImages.image(id: "u1-0-0", variant: .full, in: url, line: 0..<10) != nil)
        #expect(TranscriptImages.image(id: "u1-0-0", variant: .full, in: url, line: 0..<1_000_000_000) != nil)
    }

    @Test func servesPromptImageOriginalBytesFromItsLine() throws {
        let prompt = #"{"type":"user","uuid":"p1","message":{"role":"user","content":[{"type":"text","text":"look [Image #1]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]}}"#
        let url = try transcript([screenshotLines[0], prompt])
        defer { try? FileManager.default.removeItem(at: url) }

        let chunk = try #require(TranscriptTail.read(url, after: nil))
        let line = try #require(chunk.imageLines[TranscriptImages.promptImageID(entryID: "p1", index: 0)])
        #expect(TranscriptImages.promptImage(entryID: "p1", index: 0, in: url, line: line) == Data(base64Encoded: png))
        #expect(TranscriptImages.promptImage(entryID: "p1", index: 1, in: url, line: line) == nil)
        #expect(TranscriptImages.promptImage(entryID: "other", index: 0, in: url, line: line) == nil)
        #expect(TranscriptImages.promptImage(entryID: "p1", index: 0, in: url, line: 0..<10) == nil)
    }

    @Test func refusesIdsThatPointNowhere() throws {
        let url = try transcript(screenshotLines)
        defer { try? FileManager.default.removeItem(at: url) }

        for id in ["u1-0-1", "u1-1-0", "u9-0-0", "a1-0-0", "u1-0", "../u1-0-0", "u1\"-0-0"] {
            #expect(TranscriptImages.image(id: id, variant: .full, in: url) == nil, "\(id)")
        }
    }

    @Test func readsAnImageFileWhenTheResultOnlyHasText() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "shot-\(UUID().uuidString).png")
        try #require(Data(base64Encoded: png)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"\#(file.path)"}}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"image read"}]}}"#,
        ]
        let parsed = TranscriptTail.entries(in: Data((lines.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: [])
        #expect(parsed.entries[1].imageRefs?.map(\.id) == ["u1-0-file"])

        let url = try transcript(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(isJPEG(TranscriptImages.image(id: "u1-0-file", variant: .thumbnail, in: url)))
    }

    @Test func ignoresReadsOfOtherFiles() throws {
        let note = FileManager.default.temporaryDirectory.appending(path: "note-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: note)
        defer { try? FileManager.default.removeItem(at: note) }

        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"\#(note.path)"}}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"hello"}]}}"#,
        ]
        let parsed = TranscriptTail.entries(in: Data((lines.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: [])
        #expect(parsed.entries[1].imageRefs == nil)

        let url = try transcript(lines)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(TranscriptImages.image(id: "u1-0-file", variant: .full, in: url) == nil)
    }
}
