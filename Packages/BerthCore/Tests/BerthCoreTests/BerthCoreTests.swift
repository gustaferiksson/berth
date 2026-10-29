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

    func records(_ lines: String) -> [Record] {
        Transcript.records(in: Data(lines.utf8), dropFirst: false, dropLast: false)
    }

    @Test func orderFollowsTheLastTypedPromptNotStreamingWrites() throws {
        let head = records(#"{"type":"user","cwd":"/x","timestamp":"2026-10-29T09:00:00.000Z","message":{"content":"start"}}"#)
        let alpha = records(#"{"type":"user","timestamp":"2026-10-29T10:00:00.000Z","message":{"content":"fix alpha"}}"#)
        let beta = records(#"{"type":"user","timestamp":"2026-10-29T10:01:00.000Z","message":{"content":"fix beta"}}"#)
        let streaming = records("""
        {"type":"assistant","timestamp":"2026-10-29T10:05:00.000Z","message":{"content":[{"type":"text","text":"Working."}]}}
        {"type":"user","timestamp":"2026-10-29T10:05:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
        {"type":"user","timestamp":"2026-10-29T10:05:02.000Z","isCompactSummary":true,"message":{"content":"This session is being continued"}}
        {"type":"user","timestamp":"2026-10-29T10:05:03.000Z","origin":{"kind":"task-notification"},"message":{"content":"<task-notification>done</task-notification>"}}
        {"type":"user","timestamp":"2026-10-29T10:05:04.000Z","isSidechain":true,"message":{"content":"subagent prompt"}}
        {"type":"user","timestamp":"2026-10-29T10:05:05.000Z","isMeta":true,"message":{"content":"meta"}}
        """)
        let prompt = records(#"{"type":"user","timestamp":"2026-10-29T10:10:00.000Z","origin":{"kind":"human"},"message":{"content":"and the docs"}}"#)
        let order = { (alphaTail: [Record], betaTail: [Record]) throws -> [String] in
            let sessions = try [("alpha", alphaTail), ("beta", betaTail)].map { id, tail in
                try #require(Transcript.summary(id: id, folder: "-x", modified: .now, head: head, tail: tail))
            }
            return SessionGrouping(mode: .project, customGroups: [], repositoryRoots: [:]).groups(sessions).flatMap(\.sessions).map(\.id)
        }
        #expect(try order(alpha, beta) == ["beta", "alpha"])
        #expect(try order(alpha + streaming, beta) == ["beta", "alpha"])
        #expect(try order(alpha + streaming, beta + streaming) == ["beta", "alpha"])
        #expect(try order(alpha + streaming + prompt, beta + streaming) == ["alpha", "beta"])
        let alphaPrompt = try #require(Transcript.summary(id: "alpha", folder: "-x", modified: .now, head: head, tail: alpha + streaming)?.lastPrompt)
        #expect(alphaPrompt == (try Date("2026-10-29T10:00:00.000Z", strategy: .iso8601)))
    }

    @Test func lastPromptFallsBackToEarlierPromptThenFirstRecord() throws {
        let head = records(#"{"type":"system","cwd":"/x","timestamp":"2026-10-29T08:00:00.000Z"}"#)
        let tail = records(#"{"type":"custom-title","customTitle":"Untouched"}"#)
        let earlier = try Date("2026-10-29T09:30:00.000Z", strategy: .iso8601)
        #expect(Transcript.summary(id: "a", folder: "-x", modified: .now, head: head, tail: tail)?.lastPrompt == (try Date("2026-10-29T08:00:00.000Z", strategy: .iso8601)))
        #expect(Transcript.summary(id: "a", folder: "-x", modified: .now, head: head, tail: tail, earlierPrompt: earlier)?.lastPrompt == earlier)
    }

    @Test func lastPromptBeyondTheTailIsFoundOrKeptFromTheLastRead() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "berth-\(UUID().uuidString)/-x/prompt.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let output = String(repeating: "x", count: 4000)
        let toolResult = #"{"type":"user","timestamp":"2026-10-29T10:05:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"\#(output)"}]}}"#
        let lines = [
            #"{"type":"user","cwd":"/x","timestamp":"2026-10-29T09:00:00.000Z","message":{"content":"start"}}"#,
            #"{"type":"user","timestamp":"2026-10-29T10:00:00.000Z","message":{"content":"long task"}}"#,
        ] + Array(repeating: toolResult, count: 40)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let prompt = try Date("2026-10-29T10:00:00.000Z", strategy: .iso8601)
        #expect(Transcript.summary(of: url)?.lastPrompt == prompt)

        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Array(repeating: toolResult, count: 40).joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let known = try Date("2026-10-29T09:59:00.000Z", strategy: .iso8601)
        #expect(Transcript.summary(of: url, after: (size: size, lastPrompt: known))?.lastPrompt == known)
        #expect(Transcript.summary(of: url)?.lastPrompt == prompt)
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

    @Test func pinsKeepPinOrderAndPruneMissingSessions() {
        let now = Date()
        let sessions = [
            SessionSummary(id: "newest", cwd: "/a", title: "newest", lastActivity: now),
            SessionSummary(id: "middle", cwd: "/b", title: "middle", lastActivity: now.addingTimeInterval(-100)),
            SessionSummary(id: "oldest", cwd: "/a", title: "oldest", lastActivity: now.addingTimeInterval(-200)),
        ]
        let split = SessionPins.split(sessions, pinned: ["oldest", "deleted", "newest"])
        #expect(split.pinned.map(\.id) == ["oldest", "newest"])
        #expect(split.rest.map(\.id) == ["middle"])
        #expect(split.kept == ["oldest", "newest"])
    }

    @Test func droppingAPinOnARowTakesThatRowsPlace() {
        let pinned = ["a", "b", "c", "d"]
        #expect(SessionPins.moving(pinned, "a", onto: 3) == ["b", "c", "d", "a"])
        #expect(SessionPins.moving(pinned, "a", onto: 2) == ["b", "c", "a", "d"])
        #expect(SessionPins.moving(pinned, "d", onto: 1) == ["a", "d", "b", "c"])
        #expect(SessionPins.moving(pinned, "b", onto: 1) == pinned)
        #expect(SessionPins.moving(pinned, "gone", onto: 0) == pinned)
    }
}

struct LiveSessionTests {
    let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: "sessions")

    @Test func joinsAliveSessionsNewestFirst() {
        let live = LiveSession.load(from: directory) { $0 != 103 }
        let bySession = Dictionary(uniqueKeysWithValues: live.map { ($0.sessionId, $0) })
        #expect(bySession.count == 3)
        #expect(bySession["aaaa"]?.pid == 101)
        #expect(bySession["aaaa"]?.startedAt == 1500)
        #expect(bySession["aaaa"]?.activity == .working)
        #expect(bySession["bbbb"]?.activity == .needsInput("permission"))
        #expect(bySession["cccc"] == nil)
    }

    @Test func onlyBackgroundSessionsAreAttachable() {
        let live = LiveSession.load(from: directory) { _ in true }
        let attachable = Dictionary(uniqueKeysWithValues: live.map { ($0.sessionId, $0.attachID) })
        #expect(attachable["dddd1234-0000-4000-8000-000000000000"] == "dddd1234")
        #expect(attachable["aaaa"] == .some(nil))
        #expect(attachable["bbbb"] == .some(nil))
    }

    @Test func unknownStatusIsIdle() {
        let live = LiveSession.load(from: directory) { $0 == 103 }
        #expect(live.first?.activity == .idle)
    }
}

struct GroupingTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt; return calendar }()

    func session(_ id: String, _ cwd: String, ago: TimeInterval = 0) -> SessionSummary {
        SessionSummary(id: id, cwd: cwd, title: id, lastActivity: now.addingTimeInterval(-ago))
    }

    @Test func folderRulesMatchExactlyOrWithSubfolders() {
        let exact = FolderRule(path: "/r/acme", includesSubfolders: false)
        let nested = FolderRule(path: "/r/acme/", includesSubfolders: true)
        #expect(exact.matches("/r/acme"))
        #expect(!exact.matches("/r/acme/web"))
        #expect(nested.matches("/r/acme"))
        #expect(nested.matches("/r/acme/web"))
        #expect(!nested.matches("/r/acme-web"))
        #expect(FolderRule(path: "/", includesSubfolders: true).matches("/anything"))
    }

    @Test func projectModeGroupsByFolderMostRecentFirst() {
        let groups = SessionGrouping(mode: .project, customGroups: [], repositoryRoots: [:], now: now, calendar: calendar).groups([
            session("1", "/a", ago: 100), session("2", "/b", ago: 50), session("3", "/a"),
        ])
        #expect(groups.map(\.id) == ["/a", "/b"])
        #expect(groups.first?.sessions.map(\.id) == ["3", "1"])
        #expect(groups.first?.title == "a")
    }

    @Test func firstMatchingCustomGroupWinsAndPinsOnTop() {
        let acme = CustomGroup(name: "Acme", rules: [FolderRule(path: "/r/acme", includesSubfolders: true)])
        let web = CustomGroup(name: "Web", rules: [FolderRule(path: "/r/acme/web", includesSubfolders: false)])
        let empty = CustomGroup(name: "Empty", rules: [FolderRule(path: "/nowhere", includesSubfolders: false)])
        let groups = SessionGrouping(mode: .project, customGroups: [acme, web, empty], repositoryRoots: [:], now: now, calendar: calendar).groups([
            session("web", "/r/acme/web"), session("api", "/r/acme/api", ago: 10), session("other", "/r/other"),
        ])
        #expect(groups.map(\.title) == ["Acme", "Web", "Empty", "other"])
        #expect(groups[0].sessions.map(\.id) == ["web", "api"])
        #expect(groups[1].sessions.isEmpty)
        #expect(groups[0].folder == nil)
    }

    @Test func customGroupsKeepTheirSlotAmongAutomaticGroups() {
        let pinned = CustomGroup(name: "Pinned", rules: [FolderRule(path: "/r/pinned", includesSubfolders: false)])
        let middle = CustomGroup(name: "Middle", rules: [FolderRule(path: "/r/middle", includesSubfolders: false)], slot: 2)
        let after = CustomGroup(name: "After", rules: [FolderRule(path: "/r/after", includesSubfolders: false)])
        let last = CustomGroup(name: "Last", rules: [FolderRule(path: "/r/last", includesSubfolders: false)], slot: 50)
        let grouping = SessionGrouping(mode: .project, customGroups: [pinned, middle, after, last], repositoryRoots: [:], now: now, calendar: calendar)
        let few = grouping.groups([session("1", "/r/acme-web"), session("2", "/r/acme-api", ago: 5)])
        #expect(few.map(\.title) == ["Pinned", "acme-web", "Middle", "After", "acme-api", "Last"])
        let many = grouping.groups([session("1", "/r/acme-web"), session("2", "/r/acme-api", ago: 5), session("3", "/r/nova", ago: 9)])
        #expect(many.map(\.title) == ["Pinned", "acme-web", "Middle", "After", "acme-api", "nova", "Last"])
        let none = grouping.groups([])
        #expect(none.map(\.title) == ["Pinned", "Middle", "After", "Last"])
    }

    @Test func customGroupsSharingASlotStayInDefinitionOrder() {
        let first = CustomGroup(name: "First", rules: [], slot: 1)
        let second = CustomGroup(name: "Second", rules: [], slot: 1)
        let groups = SessionGrouping(mode: .project, customGroups: [first, second], repositoryRoots: [:], now: now, calendar: calendar).groups([
            session("1", "/r/acme-web"), session("2", "/r/acme-api", ago: 5),
        ])
        #expect(groups.map(\.title) == ["acme-web", "First", "Second", "acme-api"])
    }

    @Test func recentBucketsFillAroundCustomSlots() {
        let day: TimeInterval = 86400
        let custom = CustomGroup(name: "Acme", rules: [FolderRule(path: "/r/acme", includesSubfolders: true)], slot: 1)
        let groups = SessionGrouping(mode: .recent, customGroups: [custom], repositoryRoots: [:], now: now, calendar: calendar).groups([
            session("old", "/a", ago: 30 * day), session("today", "/b"), session("acme", "/r/acme/web"),
        ])
        #expect(groups.map(\.id) == ["recent:today", "custom:\(custom.id.uuidString)", "recent:older"])
    }

    @Test func movingAGroupStoresEveryCustomSlotInDisplayOrder() {
        let acme = CustomGroup(name: "Acme", rules: [])
        let nova = CustomGroup(name: "Nova", rules: [])
        let grouping = SessionGrouping(mode: .project, customGroups: [acme, nova], repositoryRoots: [:], now: now, calendar: calendar)
        let groups = grouping.groups([session("1", "/r/acme-web"), session("2", "/r/acme-api", ago: 5)])
        #expect(groups.map(\.title) == ["Acme", "Nova", "acme-web", "acme-api"])

        let down = SessionGrouping.moving(groups, from: 0, to: 4)
        #expect(down.map(\.name) == ["Nova", "Acme"])
        #expect(down.map(\.slot) == [0, 3])

        let up = SessionGrouping.moving(groups, from: 1, to: 0)
        #expect(up.map(\.name) == ["Nova", "Acme"])
        #expect(up.map(\.slot) == [0, 1])

        let between = SessionGrouping.moving(groups, from: 0, to: 3)
        let regrouped = SessionGrouping(mode: .project, customGroups: between, repositoryRoots: [:], now: now, calendar: calendar)
            .groups([session("1", "/r/acme-web"), session("2", "/r/acme-api", ago: 5)])
        #expect(regrouped.map(\.title) == ["Nova", "acme-web", "Acme", "acme-api"])
    }

    @Test func customGroupsSavedWithoutASlotStillDecode() throws {
        let json = #"[{"id":"6B1A4E0C-3F1D-4C55-9D7E-0A8B9C1D2E3F","name":"Acme","rules":[{"path":"/r/acme","includesSubfolders":true}]}]"#
        let groups = try JSONDecoder().decode([CustomGroup].self, from: Data(json.utf8))
        #expect(groups.map(\.name) == ["Acme"])
        #expect(groups.first?.slot == nil)
    }

    @Test func repositoryModeMergesWorktreesUnderTheirRoot() {
        let groups = SessionGrouping(mode: .repository, customGroups: [], repositoryRoots: ["/r/web-filters": "/r/web", "/r/web": "/r/web"], now: now, calendar: calendar).groups([
            session("1", "/r/web-filters"), session("2", "/r/web", ago: 5), session("3", "/r/nova", ago: 9),
        ])
        #expect(groups.map(\.id) == ["/r/web", "/r/nova"])
        #expect(groups[0].sessions.map(\.id) == ["1", "2"])
    }

    @Test func recentModeBucketsInFixedOrderAndSkipsEmptyOnes() {
        let day: TimeInterval = 86400
        let groups = SessionGrouping(mode: .recent, customGroups: [], repositoryRoots: [:], now: now, calendar: calendar).groups([
            session("old", "/a", ago: 30 * day), session("today", "/b"), session("week", "/a", ago: 3 * day),
        ])
        #expect(groups.map(\.id) == ["recent:today", "recent:thisWeek", "recent:older"])
        #expect(groups.map(\.title) == ["Today", "This Week", "Older"])
    }

    @Test func recentBucketsFollowCalendarDays() {
        let midnight = calendar.startOfDay(for: now)
        #expect(RecentBucket(date: midnight, now: now, calendar: calendar) == .today)
        #expect(RecentBucket(date: midnight.addingTimeInterval(-1), now: now, calendar: calendar) == .yesterday)
        #expect(RecentBucket(date: midnight.addingTimeInterval(-6 * 86400), now: now, calendar: calendar) == .thisWeek)
        #expect(RecentBucket(date: midnight.addingTimeInterval(-6 * 86400 - 1), now: now, calendar: calendar) == .older)
    }
}

struct RepositoryRootTests {
    @Test func resolvesWorktreesSubfoldersAndPlainFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "berth-repo-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "web")
        let worktree = root.appending(path: "web-filters")
        let gitDirectory = repo.appending(path: ".git/worktrees/web-filters")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appending(path: "packages/core"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree.appending(path: "src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "loose"), withIntermediateDirectories: true)
        try "gitdir: \(gitDirectory.path)\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: gitDirectory.appending(path: "commondir"), atomically: true, encoding: .utf8)
        #expect(RepositoryRoot.resolve(repo.path) == repo.path)
        #expect(RepositoryRoot.resolve(repo.appending(path: "packages/core").path) == repo.path)
        #expect(RepositoryRoot.resolve(worktree.appending(path: "src").path) == repo.path)
        #expect(RepositoryRoot.resolve(root.appending(path: "loose").path) == root.appending(path: "loose").path)
        #expect(RepositoryRoot.resolve("/nonexistent/berth/folder") == "/nonexistent/berth/folder")
    }
}

struct FuzzyMatchTests {
    @Test func namePrefixBeatsContainsBeatsSubsequenceBeatsPath() throws {
        let prefix = try #require(FuzzyMatch.score("no", name: "nova", path: "/r/nova"))
        let contains = try #require(FuzzyMatch.score("va", name: "nova", path: "/r/nova"))
        let subsequence = try #require(FuzzyMatch.score("na", name: "nova", path: "/r/nova"))
        let path = try #require(FuzzyMatch.score("exam", name: "nova", path: "/Users/example/nova"))
        #expect(prefix > contains && contains > subsequence && subsequence > path)
        #expect(FuzzyMatch.score("xyz", name: "nova", path: "/r/nova") == nil)
        #expect(FuzzyMatch.score("NO", name: "nova", path: "/r/nova") == prefix)
    }

    @Test func pathQueriesMatchByPrefix() {
        #expect(FuzzyMatch.score("/r/no", name: "nova", path: "/r/nova") != nil)
        #expect(FuzzyMatch.score("/r/no", name: "nova", path: "/x/nova") == nil)
    }
}

struct ClaudeLaunchTests {
    @Test(arguments: ["it's \"quoted\"", "$(touch /tmp/berth-pwned) `id` $HOME", "back\\slash\nnew line", "-p print mode", "'; exit 0; '"])
    func sessionIDReachesClaudeVerbatim(id: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "berth-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appending(path: "claude")
        try "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\0' \"$arg\"; done > \"$0.args\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", ClaudeLaunch.command(.new).replacing("/bin/zsh -ilc", with: "/bin/zsh -fc")]
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin", ClaudeLaunch.sessionVariable: id]
        try process.run()
        process.waitUntilExit()
        let args = try String(contentsOf: directory.appending(path: "claude.args"), encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).dropLast()
        #expect(args == ["--session-id", id[...]])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/berth-pwned"))
    }

    @Test func attachTakesTheJobID() {
        #expect(ClaudeLaunch.command(.attach) == #"/bin/zsh -ilc 'claude attach "$BERTH_SESSION_ID" || exec /bin/zsh -il'"#)
    }

    @Test func resumeTakesTheSessionID() {
        #expect(ClaudeLaunch.command(.resume) == #"/bin/zsh -ilc 'claude --resume "$BERTH_SESSION_ID" || exec /bin/zsh -il'"#)
    }
}

struct NeedsYouTests {
    func live(_ id: String, _ status: String) -> LiveSession {
        LiveSession(pid: 1, sessionId: id, cwd: "/Users/example/Repos/alpha", kind: nil, jobId: nil, status: status, waitingFor: nil, statusUpdatedAt: nil, startedAt: nil)
    }

    @Test func firstScanSeedsWithoutAlerting() {
        let result = NeedsYou.update(previous: nil, live: [live("a", "waiting"), live("b", "busy")], inBerth: ["a", "b"])
        #expect(result.waiting == ["a"])
        #expect(result.needsYou == ["a"])
        #expect(result.entered.isEmpty)
    }

    @Test func alertsOnceOnEnteringAndReArmsAfterLeaving() {
        var waiting: Set<String> = []
        var alerts: [[String]] = []
        for status in ["busy", "waiting", "waiting", "idle", "waiting"] {
            let result = NeedsYou.update(previous: waiting, live: [live("a", status), live("b", "busy")], inBerth: ["a", "b"])
            waiting = result.waiting
            alerts.append(result.entered.map(\.sessionId))
        }
        #expect(alerts == [[], ["a"], [], [], ["a"]])
    }

    @Test func endedSessionLeavesWaiting() {
        let result = NeedsYou.update(previous: ["a", "b"], live: [live("b", "waiting")], inBerth: ["a", "b"])
        #expect(result.waiting == ["b"])
        #expect(result.entered.isEmpty)
        #expect(NeedsYou.update(previous: result.waiting, live: [live("a", "waiting"), live("b", "waiting")], inBerth: ["a", "b"]).entered.map(\.sessionId) == ["a"])
    }

    @Test func elsewhereSessionNeitherAlertsNorCounts() {
        let result = NeedsYou.update(previous: [], live: [live("a", "waiting"), live("b", "busy")], inBerth: ["b"])
        #expect(result.waiting == ["a"])
        #expect(result.needsYou.isEmpty)
        #expect(result.entered.isEmpty)
    }

    @Test func sessionMovedIntoBerthAlertsOnlyOnNewWaiting() {
        var waiting: Set<String> = []
        var steps: [([String], Int)] = []
        for (status, inBerth) in [("waiting", Set<String>()), ("waiting", ["a"]), ("busy", ["a"]), ("waiting", ["a"])] {
            let result = NeedsYou.update(previous: waiting, live: [live("a", status)], inBerth: inBerth)
            waiting = result.waiting
            steps.append((result.entered.map(\.sessionId), result.needsYou.count))
        }
        #expect(steps.map(\.0) == [[], [], [], ["a"]])
        #expect(steps.map(\.1) == [0, 1, 0, 1])
    }
}

struct CommandPaletteTests {
    let items = [
        PaletteItem(id: "recent", section: .recentSession, title: "Settings migration", detail: "/r/alpha"),
        PaletteItem(id: "settings", section: .action, title: "Settings…", detail: "preferences"),
        PaletteItem(id: "tab", section: .openTab, title: "Fix login", detail: "/r/beta"),
        PaletteItem(id: "panel", section: .action, title: "Toggle Terminal Panel", detail: "show hide shell"),
        PaletteItem(id: "tab2", section: .openTab, title: "Set up CI", detail: "/r/gamma"),
    ]

    func ranked(_ query: String) -> [String] {
        CommandPalette.rank(query, items: items).map(\.id)
    }

    @Test func emptyQueryListsOpenTabsThenActionsWithoutRecents() {
        #expect(ranked("") == ["tab", "tab2", "settings", "panel"])
        #expect(ranked("  ") == ranked(""))
    }

    @Test func typingMixesSectionsByScore() {
        #expect(ranked("set") == ["tab2", "settings", "recent"])
        #expect(ranked("tog") == ["panel"])
        #expect(ranked("ttp") == ["panel"])
    }

    @Test func detailMatchesRankBelowTitleMatches() {
        #expect(ranked("shell") == ["panel"])
        #expect(ranked("beta") == ["tab"])
        #expect(ranked("prefe") == ["settings"])
        #expect(ranked("zzz").isEmpty)
    }

    @Test func resultsAreCapped() {
        let many = (0..<80).map { PaletteItem(id: "\($0)", section: .recentSession, title: "session \($0)", detail: "") }
        #expect(CommandPalette.rank("session", items: many).count == 50)
        #expect(CommandPalette.rank("session", items: many, limit: 3).map(\.id) == ["0", "1", "2"])
        let actions = (0..<13).map { PaletteItem(id: "\($0)", section: .action, title: "action \($0)", detail: "") }
        #expect(CommandPalette.rank("", items: actions, limit: 12).count == 13)
    }
}
