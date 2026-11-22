@testable import BerthCore
import Foundation
import Testing

struct SessionTriageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, minutesAgo: Double = 0) -> SessionSummary {
        SessionSummary(id: id, cwd: "/a", title: id, lastActivity: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func snoozeHidesUntilItsTimeThenWakesAndForgetsMissingSessions() {
        let sessions = [session("later"), session("due"), session("plain")]
        let split = SessionTriage.split(
            sessions,
            snoozes: ["later": .until(now.addingTimeInterval(60)), "due": .until(now), "gone": .until(now.addingTimeInterval(60))],
            waiting: [],
            now: now
        )
        #expect(split.awake.map(\.id) == ["due", "plain"])
        #expect(split.snoozed.map(\.id) == ["later"])
        #expect(split.woken == ["due"])
        #expect(Set(split.kept.keys) == ["later"])
    }

    @Test func untilItNeedsYouWakesOnlyWhenWaiting() {
        let sessions = [session("a"), session("b")]
        let snoozes: [String: SessionSnooze] = ["a": .needsYou, "b": .needsYou]
        let quiet = SessionTriage.split(sessions, snoozes: snoozes, waiting: [], now: now)
        #expect(quiet.snoozed.map(\.id) == ["a", "b"])
        #expect(quiet.woken.isEmpty)
        let woken = SessionTriage.split(sessions, snoozes: snoozes, waiting: ["b"], now: now)
        #expect(woken.woken == ["b"])
        #expect(woken.awake.map(\.id) == ["b"])
        #expect(woken.snoozed.map(\.id) == ["a"])
    }

    @Test func snoozedListsTheSoonestReturnFirstAndNeedsYouLast() {
        let sessions = [session("needs"), session("hour"), session("tomorrow")]
        let split = SessionTriage.split(
            sessions,
            snoozes: ["needs": .needsYou, "hour": .until(now.addingTimeInterval(3600)), "tomorrow": .until(now.addingTimeInterval(86_400))],
            waiting: [],
            now: now
        )
        #expect(split.snoozed.map(\.id) == ["hour", "tomorrow", "needs"])
    }

    @Test func tomorrowIsNineOClockLocalOnTheNextDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Stockholm"))
        let lateNight = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 23, minute: 30)))
        let earlyMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 6)))
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9)))
        #expect(SessionTriage.tomorrowMorning(after: lateNight, calendar: calendar) == expected)
        #expect(SessionTriage.tomorrowMorning(after: earlyMorning, calendar: calendar) == expected)
    }

    @Test func snoozesRoundTripThroughTheirStoredForm() {
        let until = SessionSnooze.until(now)
        #expect(SessionSnooze(stored: until.stored) == until)
        #expect(SessionSnooze(stored: SessionSnooze.needsYou.stored) == .needsYou)
        #expect(SessionSnooze(stored: "garbage") == nil)
    }

    @Test func workingAndUnreadSectionsTakeEachSessionOnceNewestFirst() {
        let sessions = [session("old-unread", minutesAgo: 30), session("busy-unread", minutesAgo: 20), session("busy", minutesAgo: 5), session("new-unread", minutesAgo: 1), session("read", minutesAgo: 2)]
        let sections = SessionTriage.sections(sessions, working: ["busy", "busy-unread"], unread: ["old-unread", "busy-unread", "new-unread"])
        #expect(sections.working.map(\.id) == ["busy", "busy-unread"])
        #expect(sections.unread.map(\.id) == ["new-unread", "old-unread"])
    }
}
