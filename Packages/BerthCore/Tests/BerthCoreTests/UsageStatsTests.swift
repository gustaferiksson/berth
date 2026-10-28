import Foundation
import Testing
@testable import BerthCore

struct UsageStatsTests {
    let calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        calendar.firstWeekday = 2
        return calendar
    }()

    func date(_ text: String) -> Date {
        try! Date("\(text)+01:00", strategy: .iso8601)
    }

    var now: Date { date("2026-03-04T12:00:00") }

    func session(_ id: String, project: String, prompts: [String] = [], replies: [(String, Int)] = []) -> (summary: SessionSummary, activity: SessionActivity) {
        (SessionSummary(id: id, cwd: "/Users/example/Repos/\(project)", title: "\(id) title", lastActivity: now),
         SessionActivity(prompts: prompts.map(date), replies: replies.map { .init(date: date($0.0), tokens: TokenUsage(input: 1, output: $0.1, cacheRead: 1000, cacheWrite: 0)) }))
    }

    @Test func tokensPerLocalDayStackedByTopProjectsWithOther() {
        let projects = (1...8).map { "p\($0)" }
        let sessions = projects.enumerated().map { index, project in
            session(project, project: project, replies: [("2026-03-03T23:30:00", 100 * (9 - index) - 1), ("2026-03-04T00:30:00", 0)])
        }
        let stats = UsageStats(sessions: sessions, now: now, calendar: calendar)
        #expect(stats.projects == ["p1", "p2", "p3", "p4", "p5", "p6", UsageStats.other])
        #expect(stats.tokensPerDay.filter { $0.day == date("2026-03-03T00:00:00") }.map(\.project) == stats.projects)
        #expect(stats.tokensPerDay.first { $0.project == UsageStats.other && $0.day == date("2026-03-03T00:00:00") }?.tokens == 300 + 200)
        #expect(stats.tokensPerDay.first { $0.project == "p1" && $0.day == date("2026-03-04T00:00:00") }?.tokens == 1)
        #expect(stats.totals.cacheRead == 16 * 1000)
        #expect(stats.sessionsPerProject.last == UsageStats.ProjectCount(project: UsageStats.other, count: 2))
    }

    @Test func windowIsThirtyLocalDays() {
        let stats = UsageStats(sessions: [
            session("old", project: "a", prompts: ["2026-02-02T23:59:00"], replies: [("2026-02-02T23:59:00", 5)]),
            session("edge", project: "b", prompts: ["2026-02-03T00:00:00"]),
        ], now: now, calendar: calendar)
        #expect(stats.start == date("2026-02-03T00:00:00"))
        #expect(stats.end == date("2026-03-05T00:00:00"))
        #expect(stats.totals == TokenUsage())
        #expect(stats.sessionsPerProject == [UsageStats.ProjectCount(project: "b", count: 1)])
        #expect(stats.mostActiveProject == UsageStats.ProjectCount(project: "b", count: 1))
    }

    @Test func promptsPerWeekdayAndHourFollowFirstWeekday() {
        let stats = UsageStats(sessions: [
            session("a", project: "a", prompts: ["2026-03-02T09:10:00", "2026-03-02T09:50:00", "2026-03-01T22:00:00"]),
        ], now: now, calendar: calendar)
        #expect(stats.promptsPerHour == [
            .init(weekday: 0, hour: 9, prompts: 2),
            .init(weekday: 6, hour: 22, prompts: 1),
        ])
    }

    @Test func thisWeekCountsSessionsAndPromptsSinceMonday() {
        let stats = UsageStats(sessions: [
            session("monday", project: "a", prompts: ["2026-03-02T08:00:00", "2026-03-04T08:00:00"]),
            session("replies only", project: "a", replies: [("2026-03-03T08:00:00", 1)]),
            session("sunday", project: "b", prompts: ["2026-03-01T23:00:00"]),
        ], now: now, calendar: calendar)
        #expect(stats.sessionsThisWeek == 2)
        #expect(stats.promptsThisWeek == 2)
        #expect(stats.mostActiveProject == UsageStats.ProjectCount(project: "a", count: 2))
    }

    @Test func longestSessionSumsGapsUpToFifteenMinutes() {
        let stats = UsageStats(sessions: [
            session("resumed", project: "a", prompts: ["2026-02-10T10:00:00", "2026-03-03T10:00:00"], replies: [("2026-02-10T10:10:00", 1), ("2026-03-03T10:15:00", 1)]),
            session("steady", project: "b", prompts: ["2026-03-04T09:00:00"], replies: [("2026-03-04T09:14:00", 1), ("2026-03-04T09:28:00", 1), ("2026-03-04T09:50:00", 1)]),
        ], now: now, calendar: calendar)
        #expect(stats.longestSession == UsageStats.LongestSession(title: "steady title", project: "b", active: 28 * 60))
    }
}
