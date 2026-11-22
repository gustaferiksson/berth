import Foundation

public nonisolated struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    public enum Severity: Sendable {
        case normal, warning, critical
    }

    public let id: String
    public let title: String
    public let length: TimeInterval
    public let used: Double
    public let resetsAt: Date

    public init(id: String, title: String, length: TimeInterval, used: Double, resetsAt: Date) {
        self.id = id
        self.title = title
        self.length = length
        self.used = min(max(used, 0), 1)
        self.resetsAt = resetsAt
    }

    public func isCurrent(at now: Date) -> Bool {
        resetsAt > now
    }

    public func pace(at now: Date) -> Double {
        min(max(1 - resetsAt.timeIntervalSince(now) / length, 0), 1)
    }

    public var usedPercent: Int {
        Int((used * 100).rounded())
    }

    public func summary(at now: Date) -> String {
        let minutes = max(Int(resetsAt.timeIntervalSince(now) / 60), 1)
        let days = minutes / 1440
        let hours = minutes / 60 % 24
        let remaining = days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
        return "Resets in \(remaining) · \(usedPercent)% used · pace \(Int((pace(at: now) * 100).rounded()))%"
    }

    public func isAhead(at now: Date) -> Bool {
        isCurrent(at: now) && used > pace(at: now)
    }

    public func severity(at now: Date) -> Severity {
        guard isCurrent(at: now), used > pace(at: now) else { return .normal }

        if used >= 0.9 { return .critical }
        return used >= 0.75 ? .warning : .normal
    }
}

public nonisolated struct PlanUsage: Codable, Sendable, Hashable {
    public static let windows: [(key: String, title: String, length: TimeInterval)] = [
        ("five_hour", "Session", 5 * 3600),
        ("seven_day", "Week", 7 * 86_400),
        ("seven_day_opus", "Week (Opus)", 7 * 86_400),
        ("seven_day_sonnet", "Week (Sonnet)", 7 * 86_400),
    ]

    public let windows: [UsageWindow]

    public init(windows: [UsageWindow]) {
        self.windows = windows
    }

    public func current(at now: Date) -> [UsageWindow] {
        windows.filter { $0.isCurrent(at: now) }
    }

    public static func parse(_ data: Data) -> Self? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let windows = Self.windows.compactMap { key, title, length -> UsageWindow? in
            guard let window = root[key] as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue,
                  let resetsAt = (window["resets_at"] as? String).flatMap(date)
            else { return nil }

            return UsageWindow(id: key, title: title, length: length, used: percent / 100, resetsAt: resetsAt)
        }
        return windows.isEmpty ? nil : Self(windows: windows)
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
