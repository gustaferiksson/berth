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
        #expect(!exact.matches("/r/acme/hub"))
        #expect(nested.matches("/r/acme"))
        #expect(nested.matches("/r/acme/hub"))
        #expect(!nested.matches("/r/acme-hub"))
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
        let hub = CustomGroup(name: "Hub", rules: [FolderRule(path: "/r/acme/hub", includesSubfolders: false)])
        let empty = CustomGroup(name: "Empty", rules: [FolderRule(path: "/nowhere", includesSubfolders: false)])
        let groups = SessionGrouping(mode: .project, customGroups: [acme, hub, empty], repositoryRoots: [:], now: now, calendar: calendar).groups([
            session("hub", "/r/acme/hub"), session("cms", "/r/acme/cms", ago: 10), session("other", "/r/other"),
        ])
        #expect(groups.map(\.title) == ["Acme", "Hub", "Empty", "other"])
        #expect(groups[0].sessions.map(\.id) == ["hub", "cms"])
        #expect(groups[1].sessions.isEmpty)
        #expect(groups[0].folder == nil)
    }

    @Test func repositoryModeMergesWorktreesUnderTheirRoot() {
        let groups = SessionGrouping(mode: .repository, customGroups: [], repositoryRoots: ["/r/hub-filters": "/r/hub", "/r/hub": "/r/hub"], now: now, calendar: calendar).groups([
            session("1", "/r/hub-filters"), session("2", "/r/hub", ago: 5), session("3", "/r/tine", ago: 9),
        ])
        #expect(groups.map(\.id) == ["/r/hub", "/r/tine"])
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
        let repo = root.appending(path: "hub")
        let worktree = root.appending(path: "hub-filters")
        let gitDirectory = repo.appending(path: ".git/worktrees/hub-filters")
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
        let prefix = try #require(FuzzyMatch.score("ti", name: "tine", path: "/r/tine"))
        let contains = try #require(FuzzyMatch.score("ne", name: "tine", path: "/r/tine"))
        let subsequence = try #require(FuzzyMatch.score("te", name: "tine", path: "/r/tine"))
        let path = try #require(FuzzyMatch.score("gus", name: "tine", path: "/Users/me/tine"))
        #expect(prefix > contains && contains > subsequence && subsequence > path)
        #expect(FuzzyMatch.score("xyz", name: "tine", path: "/r/tine") == nil)
        #expect(FuzzyMatch.score("TI", name: "tine", path: "/r/tine") == prefix)
    }

    @Test func pathQueriesMatchByPrefix() {
        #expect(FuzzyMatch.score("/r/ti", name: "tine", path: "/r/tine") != nil)
        #expect(FuzzyMatch.score("/r/ti", name: "tine", path: "/x/tine") == nil)
    }
}

struct ClaudeLaunchTests {
    @Test(arguments: ["it's \"quoted\"", "$(touch /tmp/berth-pwned) `id` $HOME", "back\\slash\nnew line", "-p print mode", "'; exit 0; '"])
    func promptReachesClaudeVerbatim(prompt: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "berth-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fake = directory.appending(path: "claude")
        try "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\0' \"$arg\"; done > \"$0.args\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", ClaudeLaunch.command(resuming: false, hasPrompt: true).replacing("/bin/zsh -ilc", with: "/bin/zsh -fc")]
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin", ClaudeLaunch.sessionVariable: "abc", ClaudeLaunch.promptVariable: prompt]
        try process.run()
        process.waitUntilExit()
        let args = try String(contentsOf: directory.appending(path: "claude.args"), encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).dropLast()
        #expect(args == ["--session-id", "abc", "--", prompt[...]])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/berth-pwned"))
    }

    @Test func noPromptMeansNoSeparator() {
        #expect(ClaudeLaunch.command(resuming: true, hasPrompt: false) == #"/bin/zsh -ilc 'claude --resume "$BERTH_SESSION_ID" || exec /bin/zsh -il'"#)
    }
}
