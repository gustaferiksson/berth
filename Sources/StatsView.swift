import BerthCore
import Charts
import SwiftUI

struct StatsView: View {
    @Environment(Store.self) private var store
    @State private var stats: UsageStats?
    @State private var selectedDay: Date?

    private var theme: GhosttyTheme { store.theme }

    var body: some View {
        ScrollView {
            if let stats, !stats.projects.isEmpty {
                content(stats)
            } else {
                ContentUnavailableView(store.searchIndexing == nil && stats != nil ? "No Activity in the Last 30 Days" : "Reading Transcripts…", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity, minHeight: 480)
            }
        }
        .foregroundStyle(theme.foreground)
        .containerBackground(theme.background ?? .clear, for: .window)
        .environment(\.ghosttyTheme, theme)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .background(WindowChrome(color: theme.background))
        .navigationTitle("Stats")
        .navigationSubtitle(store.searchIndexing.map { "Indexing \($0.done)/\($0.total)" } ?? "Last 30 days")
        .onAppear { store.updateSearchIndex() }
        .task(id: store.searchIndexVersion) {
            guard store.searchIndexVersion > 0, store.searchIndexing == nil else { return }
            stats = await Task.detached { [index = store.searchIndex, sessions = store.activeSessions + store.archivedSessions] in
                let activities = index.activities
                return UsageStats(sessions: sessions.compactMap { summary in activities[summary.id].map { (summary: summary, activity: $0) } })
            }.value
        }
    }

    private func content(_ stats: UsageStats) -> some View {
        let colors = stats.projects.enumerated().map { $1 == UsageStats.other ? theme.foreground.opacity(0.35) : theme.series[$0 % theme.series.count] }
        return VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 12) {
                tile("Sessions this week", stats.sessionsThisWeek.formatted(), weekStart)
                tile("Prompts this week", stats.promptsThisWeek.formatted(), weekStart)
                tile("Longest session", stats.longestSession.map { Duration.seconds($0.active).formatted(.units(allowed: [.hours, .minutes], width: .narrow)) } ?? "–", stats.longestSession.map { "Active time · \($0.title)" })
                tile("Most active project", stats.mostActiveProject?.project ?? "–", stats.mostActiveProject.map { "\($0.count.formatted()) prompts" })
            }
            section("Tokens per day", "Input, cache writes and output, by project") {
                tokensChart(stats, colors: colors)
                Text("30 days: \(compact(stats.totals.input)) input · \(compact(stats.totals.output)) output · \(compact(stats.totals.cacheWrite)) cache writes · \(compact(stats.totals.cacheRead)) cache reads")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                section("Sessions per project", "Sessions with activity in the last 30 days") {
                    sessionsChart(stats, colors: colors)
                }
                section("Busiest hours", "Typed prompts by weekday and hour") {
                    hoursChart(stats)
                }
            }
        }
        .padding(24)
    }

    private var weekStart: String {
        "Since \(Calendar.current.weekdaySymbols[Calendar.current.firstWeekday - 1])"
    }

    private func tile(_ label: String, _ value: String, _ caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(theme.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(caption ?? "")
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(theme.foreground.opacity(0.05), in: .rect(cornerRadius: 12))
    }

    private func section(_ title: String, _ subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(theme.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tokensChart(_ stats: UsageStats, colors: [Color]) -> some View {
        let selected = selectedDay.map { Calendar.current.startOfDay(for: $0) }
        let selectedRows = stats.tokensPerDay.filter { $0.day == selected }
        return Chart {
            ForEach(stats.tokensPerDay, id: \.self) { row in
                BarMark(x: .value("Day", row.day, unit: .day), y: .value("Tokens", row.tokens), width: .ratio(0.6))
                    .foregroundStyle(by: .value("Project", row.project))
                    .cornerRadius(2)
            }
            if let selected, !selectedRows.isEmpty {
                RuleMark(x: .value("Day", selected, unit: .day))
                    .foregroundStyle(theme.foreground.opacity(0.15))
                    .annotation(position: .trailing, alignment: .top, overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                        dayDetail(selected, rows: selectedRows, colors: colors, projects: stats.projects)
                    }
            }
        }
        .chartForegroundStyleScale(domain: stats.projects, range: colors)
        .chartXScale(domain: stats.start...stats.end)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) {
                AxisGridLine().foregroundStyle(theme.foreground.opacity(0.08))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(theme.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(theme.foreground.opacity(0.08))
                AxisValueLabel { if let tokens = value.as(Int.self) { Text(compact(tokens)) } }.foregroundStyle(theme.secondary)
            }
        }
        .chartLegend(position: .top, alignment: .leading, spacing: 12)
        .chartXSelection(value: $selectedDay)
        .frame(height: 200)
    }

    private func dayDetail(_ day: Date, rows: [UsageStats.DayTokens], colors: [Color], projects: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.caption.weight(.semibold))
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    Circle().fill(colors[projects.firstIndex(of: row.project) ?? 0]).frame(width: 8, height: 8)
                    Text(row.project)
                    Spacer(minLength: 12)
                    Text(compact(row.tokens)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .frame(width: 200)
        .padding(12)
        .background(theme.background ?? Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.foreground.opacity(0.1)) }
    }

    private func sessionsChart(_ stats: UsageStats, colors: [Color]) -> some View {
        Chart(stats.sessionsPerProject, id: \.project) { row in
            BarMark(x: .value("Sessions", row.count), y: .value("Project", row.project), height: .fixed(16))
                .foregroundStyle(by: .value("Project", row.project))
                .cornerRadius(4)
                .annotation(position: .trailing, spacing: 4) {
                    Text(row.count.formatted()).font(.caption).monospacedDigit().foregroundStyle(theme.secondary)
                }
        }
        .chartForegroundStyleScale(domain: stats.projects, range: colors)
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .extended, position: .leading) { AxisValueLabel().foregroundStyle(theme.foreground) }
        }
        .frame(height: 196)
    }

    private func hoursChart(_ stats: UsageStats) -> some View {
        let calendar = Calendar.current
        let weekdays = (0..<7).map { calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let counts = Dictionary(uniqueKeysWithValues: stats.promptsPerHour.map { ([$0.weekday, $0.hour], $0.prompts) })
        let busiest = max(counts.values.max() ?? 1, 1)
        let cells = (0..<7).flatMap { weekday in (0..<24).map { (weekday: weekday, hour: $0, prompts: counts[[weekday, $0]] ?? 0) } }
        return VStack(alignment: .leading, spacing: 8) {
            Chart(cells.indices, id: \.self) { index in
                let cell = cells[index]
                RectangleMark(x: .value("Hour", String(cell.hour)), y: .value("Weekday", weekdays[cell.weekday]), width: .ratio(0.85), height: .ratio(0.85))
                    .foregroundStyle(cell.prompts == 0 ? theme.foreground.opacity(0.05) : theme.series[0].opacity(0.25 + 0.75 * Double(cell.prompts) / Double(busiest)))
                    .cornerRadius(2)
            }
            .chartXScale(domain: (0..<24).map(String.init))
            .chartYScale(domain: weekdays)
            .chartXAxis {
                AxisMarks { AxisValueLabel().foregroundStyle(theme.secondary) }
            }
            .chartYAxis {
                AxisMarks(preset: .extended, position: .leading) { AxisValueLabel().foregroundStyle(theme.secondary) }
            }
            .frame(height: 168)
            HStack(spacing: 4) {
                Text("Fewer")
                ForEach([0.25, 0.5, 0.75, 1], id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2).fill(theme.series[0].opacity(opacity)).frame(width: 12, height: 12)
                }
                Text("More, up to \(busiest.formatted()) an hour")
            }
            .font(.caption)
            .foregroundStyle(theme.secondary)
        }
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...2)))
    }
}
