import Foundation
import Testing
@testable import BerthCore

struct TranscriptTests {
    let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    func summary(_ name: String) -> SessionSummary? {
        Transcript.summary(of: fixtures.appending(path: "\(name).jsonl"))
    }

    @Test func customTitleWinsOverAITitle() {
        #expect(summary("custom-title")?.title == "widget work")
        #expect(summary("custom-title")?.cwd == "/Users/example/Repos/alpha")
        #expect(summary("custom-title")?.id == "custom-title")
    }

    @Test func lastAITitleWins() {
        #expect(summary("ai-title")?.title == "Login bug fix")
        #expect(summary("ai-title")?.cwd == "/Users/example/Repos/beta")
    }

    @Test func firstRealPromptIsCleanedUp() {
        #expect(summary("first-prompt")?.title == "Refactor the parser so it streams")
        #expect(summary("first-prompt")?.cwd == "/Users/example/Repos/gamma")
    }

    @Test func transcriptWithoutCwdIsSkipped() {
        #expect(summary("no-cwd") == nil)
    }

    @Test func transcriptWithoutConversationIsSkipped() {
        #expect(summary("no-prompt") == nil)
    }

    @Test func tailWindowDropsPartialFirstLine() throws {
        let line = #"{"type":"ai-title","aiTitle":"Tail title","cwd":"/x"}"#
        let data = Data(("garbage partial line\n" + line + "\n").utf8)
        let records = Transcript.records(in: data, dropFirst: true, dropLast: false)
        #expect(records.count == 1)
        #expect(records.first?.aiTitle == "Tail title")
    }

    @Test func groupsSortByMostRecentActivity() {
        let now = Date()
        let groups = ProjectGroup.grouped([
            SessionSummary(id: "1", cwd: "/a", title: "one", modified: now.addingTimeInterval(-100)),
            SessionSummary(id: "2", cwd: "/b", title: "two", modified: now.addingTimeInterval(-50)),
            SessionSummary(id: "3", cwd: "/a", title: "three", modified: now),
        ])
        #expect(groups.map(\.cwd) == ["/a", "/b"])
        #expect(groups.first?.sessions.map(\.id) == ["3", "1"])
        #expect(groups.first?.name == "a")
    }
}

struct LiveSessionTests {
    let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: "sessions")

    @Test func joinsAliveSessionsNewestFirst() {
        let live = LiveSession.load(from: directory) { $0 != 103 }
        let bySession = Dictionary(uniqueKeysWithValues: live.map { ($0.sessionId, $0) })
        #expect(bySession.count == 2)
        #expect(bySession["aaaa"]?.pid == 101)
        #expect(bySession["aaaa"]?.activity == .working)
        #expect(bySession["bbbb"]?.activity == .needsInput("permission"))
        #expect(bySession["cccc"] == nil)
    }

    @Test func unknownStatusIsIdle() {
        let live = LiveSession.load(from: directory) { $0 == 103 }
        #expect(live.first?.activity == .idle)
    }
}
