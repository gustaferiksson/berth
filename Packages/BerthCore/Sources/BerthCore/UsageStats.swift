import Foundation

public struct TokenUsage: Sendable, Hashable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var new: Int { input + output + cacheWrite }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

public struct SessionActivity: Sendable, Hashable {
    public struct Reply: Sendable, Hashable {
        public let date: Date
        public let tokens: TokenUsage

        public init(date: Date, tokens: TokenUsage) {
            self.date = date
            self.tokens = tokens
        }
    }

    public var prompts: [Date]
    public var replies: [Reply]

    public init(prompts: [Date] = [], replies: [Reply] = []) {
        self.prompts = prompts
        self.replies = replies
    }
}

public struct UsageStats: Sendable {
    public struct DayTokens: Sendable, Hashable {
        public let day: Date
        public let project: String
        public let tokens: Int
    }

    public struct ProjectCount: Sendable, Hashable {
        public let project: String
        public let count: Int
    }

    public struct HourPrompts: Sendable, Hashable {
        public let weekday: Int
        public let hour: Int
        public let prompts: Int
    }

    public struct LongestSession: Sendable, Hashable {
        public let title: String
        public let project: String
        public let active: TimeInterval
    }

    public static let other = "Other"
    public static let topProjects = 6
    public static let idleGap: TimeInterval = 15 * 60

    public let start: Date
    public let end: Date
    public let projects: [String]
    public let tokensPerDay: [DayTokens]
    public let sessionsPerProject: [ProjectCount]
    public let promptsPerHour: [HourPrompts]
    public let totals: TokenUsage
    public let sessionsThisWeek: Int
    public let promptsThisWeek: Int
    public let longestSession: LongestSession?
    public let mostActiveProject: ProjectCount?

    public init(sessions: [(summary: SessionSummary, activity: SessionActivity)], now: Date = .now, calendar: Calendar = .current, days: Int = 30) {
        let today = calendar.startOfDay(for: now)
        start = calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
        end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let window = start..<end
        let recent = sessions.map { session in
            (summary: session.summary,
             project: URL(filePath: session.summary.cwd).lastPathComponent,
             prompts: session.activity.prompts.filter(window.contains),
             replies: session.activity.replies.filter { window.contains($0.date) })
        }.filter { !$0.prompts.isEmpty || !$0.replies.isEmpty }

        let tokensByProject = recent.reduce(into: [String: Int]()) { $0[$1.project, default: 0] += $1.replies.reduce(0) { $0 + $1.tokens.new } }
        let ranked = tokensByProject.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let top = Set(ranked.prefix(Self.topProjects))
        let projects = Array(ranked.prefix(Self.topProjects)) + (ranked.count > Self.topProjects ? [Self.other] : [])
        self.projects = projects
        let label = { (project: String) in top.contains(project) ? project : Self.other }

        let perDay = recent.flatMap { session in session.replies.map { (calendar.startOfDay(for: $0.date), label(session.project), $0.tokens.new) } }
            .reduce(into: [Date: [String: Int]]()) { $0[$1.0, default: [:]][$1.1, default: 0] += $1.2 }
        tokensPerDay = perDay.keys.sorted().flatMap { day in
            projects.compactMap { project in perDay[day]?[project].map { DayTokens(day: day, project: project, tokens: $0) } }
        }
        let sessionCounts = Dictionary(grouping: recent) { label($0.project) }
        sessionsPerProject = projects.map { ProjectCount(project: $0, count: sessionCounts[$0]?.count ?? 0) }

        let cells = recent.flatMap(\.prompts).reduce(into: [[Int]: Int]()) { cells, prompt in
            let weekday = (calendar.component(.weekday, from: prompt) - calendar.firstWeekday + 7) % 7
            cells[[weekday, calendar.component(.hour, from: prompt)], default: 0] += 1
        }
        promptsPerHour = cells.map { HourPrompts(weekday: $0.key[0], hour: $0.key[1], prompts: $0.value) }
            .sorted { ($0.weekday, $0.hour) < ($1.weekday, $1.hour) }

        totals = recent.flatMap(\.replies).reduce(TokenUsage()) { $0 + $1.tokens }
        let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: today, duration: 0)
        sessionsThisWeek = recent.filter { $0.prompts.contains(where: week.contains) || $0.replies.contains { week.contains($0.date) } }.count
        promptsThisWeek = recent.flatMap(\.prompts).filter(week.contains).count

        longestSession = recent.map { session in
            let times = (session.prompts + session.replies.map(\.date)).sorted()
            let active = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 <= Self.idleGap }.reduce(0, +)
            return LongestSession(title: session.summary.title, project: session.project, active: active)
        }.max { $0.active < $1.active }
        mostActiveProject = Dictionary(grouping: recent, by: \.project)
            .map { ProjectCount(project: $0.key, count: $0.value.reduce(0) { $0 + $1.prompts.count }) }
            .filter { $0.count > 0 }
            .max { $0.count != $1.count ? $0.count < $1.count : $0.project > $1.project }
    }
}
