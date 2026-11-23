@testable import BerthCore
import Foundation
import Testing

struct CodexLiveTests {
    @Test func parsesRunStateTitles() {
        #expect(CodexRunState(title: "⠋ ThInKiNg…") == .working)
        #expect(CodexRunState(title: "Working on it") == .working)
        #expect(CodexRunState(title: "  • NEEDS INPUT") == .needsInput)
        #expect(CodexRunState(title: "[ . ] Action Required") == .needsInput)
        #expect(CodexRunState(title: "[ ! ] Action Required") == .needsInput)
        #expect(CodexRunState(title: "⠦ Working") == .working)
        #expect(CodexRunState(title: "Blocked") == .needsInput)
        #expect(CodexRunState(title: "ready") == .ready)
        for title in ["", "⠋", "Starting", "/work/fixture", "/Ready/project", "~/Thinking"] {
            #expect(CodexRunState(title: title) == nil)
        }
    }

    @Test func rolloutTracksTheNewestTurn() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        let filler = String(repeating: "x", count: CodexRollout.tailBytes)
        let cases = [
            (["task_started"], true),
            (["task_started", "task_complete"], false),
            (["task_started", "turn_aborted"], false),
            (["task_started", "task_complete", "task_started"], true),
            (["task_complete", filler, "task_started"], true),
            (["task_started", filler], true),
        ]
        for (events, isOpen) in cases {
            try writeRollout(events, to: url, modified: modified)
            let state = try #require(CodexRollout.turnState(of: url))
            #expect(state.isOpen == isOpen)
            #expect(state.modified == modified)
        }
    }

    @Test func sessionsPreferTitlesAndFallBackToRecentOpenTurns() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let modified = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let opened = modified - 900
        let stale = modified - 600
        let openURL = directory.appending(path: "open.jsonl")
        let closedURL = directory.appending(path: "closed.jsonl")
        let staleURL = directory.appending(path: "stale.jsonl")
        let missingURL = directory.appending(path: "missing.jsonl")
        try writeRollout(["task_started"], to: openURL, modified: modified)
        try writeRollout(["task_started", "task_complete"], to: closedURL, modified: modified)
        try writeRollout(["task_started"], to: staleURL, modified: stale)

        let cases: [(id: String, title: String, transcript: URL?, status: String, reportsWaiting: Bool, updated: Date)] = [
            ("thinking", "Thinking", closedURL, "busy", true, modified),
            ("working", "Working", nil, "busy", true, opened),
            ("needs-input", "Needs input", openURL, "waiting", true, modified),
            ("blocked", "[ ! ] Action Required", nil, "waiting", true, opened),
            ("ready", "Ready", openURL, "idle", true, modified),
            ("recent", "unknown", openURL, "busy", false, modified),
            ("complete", "", closedURL, "idle", false, modified),
            ("stale", "", staleURL, "idle", false, stale),
            ("missing", "", missingURL, "idle", false, opened),
            ("no-transcript", "", nil, "idle", false, opened),
        ]
        let tabs = cases.map { fixture in
            LiveProbe.Tab(sessionID: fixture.id, cwd: "/work", terminalTitle: fixture.title, opened: opened, transcript: fixture.transcript)
        } + [LiveProbe.Tab(sessionID: "", cwd: "/work", terminalTitle: "Thinking", opened: opened, transcript: nil)]
        let probe = LiveProbe(directory: directory, tabs: tabs)
        let records = CodexLive.sessions(probe)
        #expect(records.map(\.sessionId) == cases.map(\.id))
        #expect(records == CodexLive.sessions(probe))
        for (record, expected) in zip(records, cases) {
            #expect(record.pid == 0)
            #expect(record.kind == "tab")
            #expect(record.cwd == "/work")
            #expect(record.status == expected.status)
            #expect(record.waitingFor == (expected.status == "waiting" ? "action required" : nil))
            #expect(record.observesWaiting == expected.reportsWaiting)
            #expect(record.reportsWaiting == expected.reportsWaiting)
            #expect(record.startedAt == opened.timeIntervalSince1970 * 1000)
            #expect(record.statusUpdatedAt == expected.updated.timeIntervalSince1970 * 1000)
        }
    }

    private func writeRollout(_ events: [String], to url: URL, modified: Date) throws {
        let lines = events.map { event in
            #"{"timestamp":"2026-01-02T10:00:00.000Z","type":"event_msg","payload":{"type":"\#(event)"}}"#
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
