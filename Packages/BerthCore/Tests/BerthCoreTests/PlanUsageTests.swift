import BerthCore
import Foundation
import Testing

struct PlanUsageTests {
    private let reset = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(used: Double) -> UsageWindow {
        UsageWindow(id: "five_hour", title: "Session", length: 5 * 3600, used: used, resetsAt: reset)
    }

    @Test func paceIsTheElapsedShareOfTheWindow() {
        let now = reset.addingTimeInterval(-2.5 * 3600)
        #expect(window(used: 0.1).pace(at: now) == 0.5)
        #expect(window(used: 0.1).pace(at: reset.addingTimeInterval(-5 * 3600)) == 0)
        #expect(window(used: 0.1).pace(at: reset.addingTimeInterval(-6 * 3600)) == 0)
    }

    @Test func summaryReadsResetUsedAndPace() {
        let now = reset.addingTimeInterval(-(2 * 3600 + 14 * 60))
        #expect(window(used: 0.63).summary(at: now) == "Resets in 2h 14m · 63% used · pace 55%")
        #expect(window(used: 0.63).summary(at: reset.addingTimeInterval(-30)).hasPrefix("Resets in 1m"))
    }

    @Test func windowEndsAtItsReset() {
        #expect(window(used: 0.5).isCurrent(at: reset.addingTimeInterval(-1)))
        #expect(!window(used: 0.5).isCurrent(at: reset))
        #expect(!window(used: 0.5).isCurrent(at: reset.addingTimeInterval(60)))
    }

    @Test func severityNeedsBeingAheadOfPaceAndNearTheLimit() {
        let halfway = reset.addingTimeInterval(-2.5 * 3600)
        #expect(window(used: 0.4).severity(at: halfway) == .normal)
        #expect(window(used: 0.8).severity(at: halfway) == .warning)
        #expect(window(used: 0.95).severity(at: halfway) == .critical)
        #expect(window(used: 0.95).severity(at: reset.addingTimeInterval(-60)) == .normal)
        #expect(window(used: 0.8).severity(at: reset.addingTimeInterval(-60)) == .normal)
        #expect(window(used: 0.95).severity(at: reset.addingTimeInterval(60)) == .normal)
    }

    @Test func parsesTheWindowsTheResponseHas() throws {
        let json = """
        {"five_hour": {"utilization": 37.0, "resets_at": "2027-01-15T08:00:00.123456+00:00"},
         "seven_day": {"utilization": 62, "resets_at": "2027-01-18T00:00:00Z"},
         "seven_day_opus": null, "extra_usage": {"is_enabled": false}}
        """
        let usage = try #require(PlanUsage.parse(Data(json.utf8)))
        #expect(usage.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(usage.windows[0].used == 0.37)
        #expect(usage.windows[1].used == 0.62)
        #expect(usage.windows[1].length == 7 * 86_400)
    }

    @Test func skipsWindowsWithMissingData() {
        let json = """
        {"five_hour": {"utilization": 10}, "seven_day": {"resets_at": "2027-01-18T00:00:00Z"},
         "seven_day_sonnet": {"utilization": 250, "resets_at": "not a date"}}
        """
        #expect(PlanUsage.parse(Data(json.utf8)) == nil)
        #expect(PlanUsage.parse(Data("[]".utf8)) == nil)
        #expect(PlanUsage.parse(Data("nope".utf8)) == nil)
    }

    @Test func clampsUsageAndDropsWindowsThatReset() throws {
        let json = #"{"five_hour": {"utilization": 130, "resets_at": "2027-01-15T08:00:00Z"}}"#
        let usage = try #require(PlanUsage.parse(Data(json.utf8)))
        #expect(usage.windows[0].used == 1)
        let after = try #require(ISO8601DateFormatter().date(from: "2027-01-15T08:00:01Z"))
        #expect(usage.current(at: after).isEmpty)
    }
}
