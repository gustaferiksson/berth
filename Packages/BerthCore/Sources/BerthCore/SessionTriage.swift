import Foundation

public enum SessionSnooze: Equatable, Sendable {
    case until(Date)
    case needsYou

    public init?(stored: Any) {
        if let seconds = stored as? Double {
            self = .until(Date(timeIntervalSince1970: seconds))
        } else if stored as? String == "needsYou" {
            self = .needsYou
        } else {
            return nil
        }
    }

    public var stored: Any {
        if case let .until(date) = self { return date.timeIntervalSince1970 }

        return "needsYou"
    }
}

public enum SessionTriage {
    public static func tomorrowMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    public static func split(
        _ sessions: [SessionSummary],
        snoozes: [String: SessionSnooze],
        waiting: Set<String>,
        now: Date
    ) -> (awake: [SessionSummary], snoozed: [SessionSummary], kept: [String: SessionSnooze], woken: [String]) {
        let listed = sessions.filter { snoozes[$0.id] != nil }
        let woken = listed.filter { session in
            guard let snooze = snoozes[session.id] else { return false }

            if case let .until(date) = snooze { return date <= now }

            return waiting.contains(session.id)
        }.map(\.id)
        let wokenIDs = Set(woken)
        let snoozed = listed.filter { !wokenIDs.contains($0.id) }
        let kept = Dictionary(uniqueKeysWithValues: snoozed.compactMap { session in snoozes[session.id].map { (session.id, $0) } })
        let order = { (session: SessionSummary) -> (Date, Date) in
            if case let .until(date) = kept[session.id] { return (date, session.lastPrompt) }

            return (.distantFuture, session.lastPrompt)
        }
        return (
            sessions.filter { kept[$0.id] == nil },
            snoozed.sorted { order($0).0 != order($1).0 ? order($0).0 < order($1).0 : order($0).1 > order($1).1 },
            kept,
            woken.sorted()
        )
    }

    public static func sections(
        _ sessions: [SessionSummary],
        working: Set<String>,
        unread: Set<String>
    ) -> (working: [SessionSummary], unread: [SessionSummary]) {
        let newestFirst = { (lhs: SessionSummary, rhs: SessionSummary) in lhs.lastActivity > rhs.lastActivity }
        return (
            sessions.filter { working.contains($0.id) }.sorted(by: newestFirst),
            sessions.filter { !working.contains($0.id) && unread.contains($0.id) }.sorted(by: newestFirst)
        )
    }
}
