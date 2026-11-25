import BerthCore
import SwiftUI

struct UsageBar: View {
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage(PlanUsageFetch.enabledKey) private var showsPlanUsage = false
    @AppStorage(GeneralSettings.codexKey) private var isCodexEnabled = false

    var body: some View {
        if showsPlanUsage {
            TimelineView(.everyMinute) { timeline in
                let groups = UsageGroup.groups(claude: store.planUsage, codex: isCodexEnabled ? store.codexUsage : nil, at: timeline.date)
                if !groups.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(groups) { group in
                            Button { store.isStatsRequested = true } label: {
                                HStack(spacing: 8) {
                                    if groups.count > 1 || group.kind == .codex {
                                        Image(group.kind == .codex ? Harness.codex.asset : Harness.claude.asset)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 12, height: 12)
                                            .foregroundStyle(theme.secondary)
                                            .accessibilityHidden(true)
                                    }
                                    VStack(spacing: 5) {
                                        ForEach(group.windows.prefix(2)) { window in
                                            UsageWindowRow(window: window, now: timeline.date, harness: group.name, staleSince: group.staleSince)
                                        }
                                    }
                                }
                                .opacity(group.staleSince == nil ? 1 : 0.5)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens Stats")
                            .padding(10)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                    }
                }
            }
        }
    }
}

struct UsageWindowRow: View {
    @Environment(\.ghosttyTheme) private var theme

    let window: UsageWindow
    let now: Date
    var harness = "Claude"
    var staleSince: Date?

    private var summary: String {
        let current = window.summary(at: now, harness: harness)
        guard let staleSince else { return current }

        return "\(current). Last reported \(staleSince.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(window.title)
                .foregroundStyle(theme.secondary)
                .frame(width: 52, alignment: .leading)
            UsageTrack(window: window, now: now)
            Text("\(window.usedPercent)%")
                .monospacedDigit()
                .foregroundStyle(UsageTrack.aheadTint(window, now: now, theme: theme) ?? theme.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .font(.caption)
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(harness) \(window.title)")
        .accessibilityValue(window.isAhead(at: now) ? "\(summary), ahead of pace" : summary)
    }
}

struct UsageTrack: View {
    @Environment(\.ghosttyTheme) private var theme

    let window: UsageWindow
    let now: Date

    @AppStorage("showsSessionUsageDivisions") private var showsSessionDivisions = false
    @AppStorage("showsWeeklyUsageDivisions") private var showsWeeklyDivisions = false
    @State private var width = 0.0

    private var isWeekly: Bool { window.length >= 2 * 86_400 }

    private var divisions: Int {
        Int((window.length / (isWeekly ? 86_400 : 3600)).rounded())
    }

    static func aheadTint(_ window: UsageWindow, now: Date, theme: GhosttyTheme) -> Color? {
        guard window.isAhead(at: now) else { return nil }

        return window.severity(at: now) == .critical ? theme.closed : theme.needsYou
    }

    private var fill: Color {
        switch window.severity(at: now) {
        case .normal: theme.foreground.opacity(0.55)
        case .warning: theme.needsYou
        case .critical: theme.closed
        }
    }

    private var isOvershootOnly: Bool {
        window.isAhead(at: now) && window.severity(at: now) == .normal
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Color(theme.foreground.opacity(0.14))
                if isWeekly ? showsWeeklyDivisions : showsSessionDivisions, divisions > 1 {
                    ForEach(1..<divisions, id: \.self) { slot in
                        Rectangle()
                            .fill(theme.foreground.opacity(0.18))
                            .frame(width: 1)
                            .offset(x: width * Double(slot) / Double(divisions) - 0.5)
                    }
                }
                Rectangle()
                    .fill(fill)
                    .frame(width: width * (isOvershootOnly ? window.pace(at: now) : window.used))
                if isOvershootOnly {
                    Rectangle()
                        .fill(theme.needsYou.opacity(0.7))
                        .frame(width: width * (window.used - window.pace(at: now)))
                        .offset(x: width * window.pace(at: now))
                }
                if window.pace(at: now) > 0 {
                    Capsule()
                        .fill(theme.foreground)
                        .frame(width: 1.5, height: 10)
                        .offset(x: min(width * window.pace(at: now), width - 1.5))
                }
            }
            .clipShape(.capsule)
        }
        .frame(height: 10)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}
