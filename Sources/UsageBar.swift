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
            Text(window.used, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .foregroundStyle(theme.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .font(.caption)
        .help(window.summary(at: now))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.title)
        .accessibilityValue(window.summary(at: now))
    }
}

struct UsageTrack: View {
    @Environment(\.ghosttyTheme) private var theme

    let window: UsageWindow
    let now: Date

    @State private var width = 0.0

    private var fill: Color {
        switch window.severity(at: now) {
        case .normal: theme.foreground.opacity(0.55)
        case .warning: theme.needsYou
        case .critical: theme.closed
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Color(theme.foreground.opacity(0.14))
                Rectangle()
                    .fill(fill)
                    .frame(width: width * window.used)
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
