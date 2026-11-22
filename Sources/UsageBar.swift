import BerthCore
import SwiftUI

struct UsageBar: View {
    @Environment(Store.self) private var store
    @AppStorage(PlanUsageFetch.enabledKey) private var showsPlanUsage = false

    var body: some View {
        if showsPlanUsage, let usage = store.planUsage {
            TimelineView(.everyMinute) { timeline in
                let windows = usage.current(at: timeline.date).prefix(2)
                if !windows.isEmpty {
                    Button { store.isStatsRequested = true } label: {
                        VStack(spacing: 5) {
                            ForEach(windows) { UsageWindowRow(window: $0, now: timeline.date) }
                        }
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

struct UsageWindowRow: View {
    @Environment(\.ghosttyTheme) private var theme

    let window: UsageWindow
    let now: Date

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
        .help(window.summary(at: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue(window.isAhead(at: now) ? "\(window.summary(at: now)), ahead of pace" : window.summary(at: now))
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
            }
            .clipShape(.capsule)
            Capsule()
                .fill(theme.foreground)
                .frame(width: 1.5, height: 10)
                .offset(x: min(width * window.pace(at: now), width - 1.5))
        }
        .frame(height: 10)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}
