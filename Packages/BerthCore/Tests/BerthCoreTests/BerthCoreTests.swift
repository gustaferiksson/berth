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

    @Test func movedSessionLivesInItsRelocatedFolder() {
        #expect(summary("-Users-example-Repos-delta/moved")?.cwd == "/Users/example/Repos/delta")
    }

    @Test func folderIsTheCwdMatchingTheProjectSlugNotABashCd() {
        let records = Transcript.records(in: Data("""
        {"type":"user","cwd":"/Users/example/Repos/alpha","message":{"content":"hi"}}
        {"type":"assistant","cwd":"/Users/example/Repos/delta"}
        {"type":"assistant","cwd":"/Users/example/Repos/delta/docs"}
        """.utf8), dropFirst: false, dropLast: false)
        let movedOutOfTail = Transcript.summary(id: "a", folder: "-Users-example-Repos-delta", modified: .now, head: Array(records.prefix(1)), tail: Array(records.dropFirst()))
        let bashCdOnly = Transcript.summary(id: "b", folder: "-Users-example-Repos-alpha", modified: .now, head: Array(records.prefix(1)), tail: Array(records.suffix(1)))
        let unknownSlug = Transcript.summary(id: "c", folder: "ssh-1234", modified: .now, head: Array(records.prefix(1)), tail: Array(records.dropFirst()))
        #expect(movedOutOfTail?.cwd == "/Users/example/Repos/delta")
        #expect(bashCdOnly?.cwd == "/Users/example/Repos/alpha")
        #expect(unknownSlug?.cwd == "/Users/example/Repos/alpha")
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

    @Test func branchIsTheLastRecordedOneAndDetachedHeadIsDropped() {
        let head = Transcript.records(in: Data(#"{"type":"user","cwd":"/x","gitBranch":"main","message":{"content":"hi"}}"#.utf8), dropFirst: false, dropLast: false)
        let tail = Transcript.records(in: Data("""
        {"type":"assistant","gitBranch":"main"}
        {"type":"assistant","gitBranch":"feat/cards"}
        {"type":"ai-title","aiTitle":"Cards"}
        """.utf8), dropFirst: false, dropLast: false)
        let detached = Transcript.records(in: Data(#"{"type":"assistant","gitBranch":"HEAD"}"#.utf8), dropFirst: false, dropLast: false)
        #expect(Transcript.summary(id: "a", folder: "-x", modified: .now, head: head, tail: tail)?.branch == "feat/cards")
        #expect(Transcript.summary(id: "b", folder: "-x", modified: .now, head: head, tail: detached)?.branch == nil)
    }

    @Test func pullRequestIsTheLastLinkedOne() {
        let head = Transcript.records(in: Data(#"{"type":"user","cwd":"/x","message":{"content":"hi"}}"#.utf8), dropFirst: false, dropLast: false)
        let tail = Transcript.records(in: Data("""
        {"type":"pr-link","prNumber":7,"prUrl":"https://github.com/example/alpha/pull/7","prRepository":"example/alpha"}
        {"type":"pr-link","prNumber":9,"prUrl":"https://github.com/example/alpha/pull/9","prRepository":"example/alpha"}
        """.utf8), dropFirst: false, dropLast: false)
        let pullRequest = Transcript.summary(id: "a", folder: "-x", modified: .now, head: head, tail: tail)?.pullRequest
        #expect(pullRequest?.number == 9)
        #expect(pullRequest?.repository == "example/alpha")
        #expect(Transcript.summary(id: "b", folder: "-x", modified: .now, head: head, tail: [])?.pullRequest == nil)
    }

    @Test func resumingWithoutConversationKeepsTheOldActivity() throws {
        let head = Transcript.records(in: Data("""
        {"type":"user","cwd":"/x","timestamp":"2026-10-01T10:00:00.000Z","message":{"content":"fix the parser"}}
        {"type":"assistant","timestamp":"2026-10-01T10:05:00.000Z","message":{"content":[{"type":"text","text":"Done."}]}}
        """.utf8), dropFirst: false, dropLast: false)
        let resumed = Transcript.records(in: Data("""
        {"type":"assistant","timestamp":"2026-10-01T10:05:00.000Z","message":{"content":[{"type":"text","text":"Done."}]}}
        {"type":"ai-title","aiTitle":"Parser fix"}
        {"type":"permission-mode","permissionMode":"auto"}
        {"type":"file-history-snapshot"}
        {"type":"system","timestamp":"2026-10-28T09:00:00.000Z"}
        {"type":"user","timestamp":"2026-10-28T09:00:01.000Z","isMeta":true,"message":{"content":"Caveat: local command"}}
        """.utf8), dropFirst: false, dropLast: false)
        let replied = resumed + Transcript.records(in: Data(#"{"type":"user","timestamp":"2026-10-28T09:01:00.000Z","message":{"content":"and the tests"}}"#.utf8), dropFirst: false, dropLast: false)
        let resumedActivity = try #require(Transcript.summary(id: "a", folder: "-x", modified: .now, head: head, tail: resumed)?.lastActivity)
        let repliedActivity = try #require(Transcript.summary(id: "a", folder: "-x", modified: .now, head: head, tail: replied)?.lastActivity)
        #expect(resumedActivity == (try Date("2026-10-01T10:05:00.000Z", strategy: .iso8601)))
        #expect(repliedActivity == (try Date("2026-10-28T09:01:00.000Z", strategy: .iso8601)))
    }

    @Test func groupsSortByMostRecentActivity() {
        let now = Date()
        let groups = ProjectGroup.grouped([
            SessionSummary(id: "1", cwd: "/a", title: "one", lastActivity: now.addingTimeInterval(-100)),
            SessionSummary(id: "2", cwd: "/b", title: "two", lastActivity: now.addingTimeInterval(-50)),
            SessionSummary(id: "3", cwd: "/a", title: "three", lastActivity: now),
        ])
        #expect(groups.map(\.cwd) == ["/a", "/b"])
        #expect(groups.first?.sessions.map(\.id) == ["3", "1"])
        #expect(groups.first?.name == "a")
    }

    @Test func archiveHidesUntilNewActivityAndPrunesMissingTranscripts() {
        let now = Date()
        let sessions = [
            SessionSummary(id: "quiet", cwd: "/a", title: "quiet", lastActivity: now.addingTimeInterval(-100)),
            SessionSummary(id: "older", cwd: "/a", title: "older", lastActivity: now.addingTimeInterval(-200)),
            SessionSummary(id: "replied", cwd: "/a", title: "replied", lastActivity: now),
            SessionSummary(id: "open", cwd: "/a", title: "open", lastActivity: now),
        ]
        let split = SessionArchive.split(sessions, archivedAt: [
            "quiet": now.addingTimeInterval(-50),
            "older": now.addingTimeInterval(-50),
            "replied": now.addingTimeInterval(-10),
            "deleted": now,
        ])
        #expect(split.active.map(\.id) == ["replied", "open"])
        #expect(split.archived.map(\.id) == ["quiet", "older"])
        #expect(Set(split.kept.keys) == ["quiet", "older"])
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
