import SwiftUI

struct UsageSummary: View {
    let usage: PlanUsage
    let open: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let windows = usage.current(at: timeline.date)
            if !windows.isEmpty {
                Button(action: open) {
                    VStack(spacing: 10) {
                        ForEach(windows.prefix(2)) { window in
                            HStack(spacing: 10) {
                                Text(window.title)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                UsageTrack(window: window, now: timeline.date, height: 8)
                                Text(window.used, format: .percent.precision(.fractionLength(0)))
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(window.title)
                            .accessibilityValue(window.summary(at: timeline.date))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows plan usage")
            }
        }
    }
}

struct UsageTrack: View {
    let window: UsageWindow
    let now: Date
    let height: CGFloat

    @State private var width = 0.0

    private var fill: Color {
        switch window.severity(at: now) {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle()
                    .fill(fill)
                    .frame(width: width * window.used)
            }
            .clipShape(.capsule)
            Capsule()
                .fill(.primary)
                .frame(width: 2, height: height + 6)
                .offset(x: min(width * window.pace(at: now), width - 2))
        }
        .frame(height: height + 6)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}

struct UsageSheet: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { timeline in
                let windows = client.usage?.current(at: timeline.date) ?? []
                List {
                    ForEach(windows) { window in
                        Section(window.title) {
                            UsageTrack(window: window, now: timeline.date, height: 10)
                                .listRowSeparator(.hidden)
                                .accessibilityHidden(true)
                            LabeledContent("Used", value: window.used.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Pace", value: window.pace(at: timeline.date).formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Resets", value: window.resetsAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(window.summary(at: timeline.date))
                    }
                    Section {} footer: {
                        Text("The line on each bar marks how much of the window has passed. Usage past the line is faster than an even pace.")
                    }
                }
                .overlay {
                    if windows.isEmpty {
                        ContentUnavailableView("No Usage Yet", systemImage: "gauge.with.dots.needle.33percent", description: Text("Berth hasn’t read your plan usage."))
                    }
                }
            }
            .navigationTitle("Plan Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: client.state) {
                guard client.state == .connected else { return }

                client.loadUsage()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
