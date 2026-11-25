import SwiftUI

extension RemoteClient {
    func usageGroups(at now: Date) -> [UsageGroup] {
        UsageGroup.groups(claude: usage, codex: codexUsage, at: now)
    }
}

struct UsageCard: View {
    let group: UsageGroup
    let open: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(group.kind == .codex ? "HarnessCodex" : "HarnessClaude")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        ForEach(group.windows.prefix(2)) { window in
                            HStack(spacing: 10) {
                                Text(window.title)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                UsageTrack(window: window, now: timeline.date)
                                Text("\(window.usedPercent)%")
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(UsageTrack.aheadTint(window, now: timeline.date) ?? .secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(group.name) \(window.title)")
                            .accessibilityValue(group.spoken(window, at: timeline.date))
                        }
                        if let staleSince = group.staleSince {
                            Text("Updated \(staleSince.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows plan usage")
        }
    }
}

extension UsageGroup {
    func spoken(_ window: UsageWindow, at now: Date) -> String {
        let summary = window.summary(at: now, harness: name)
        let current = window.isAhead(at: now) ? "\(summary), ahead of pace" : summary
        guard let staleSince else { return current }

        return "\(current). Last reported \(staleSince.formatted(.relative(presentation: .named)))"
    }
}

struct UsageTrack: View {
    let window: UsageWindow
    let now: Date

    @State private var width = 0.0

    static func aheadTint(_ window: UsageWindow, now: Date) -> Color? {
        guard window.isAhead(at: now) else { return nil }

        return window.severity(at: now) == .critical ? Color(SyntaxPalette.critical) : Color(SyntaxPalette.warning)
    }

    private var isOvershootOnly: Bool {
        window.isAhead(at: now) && window.severity(at: now) == .normal
    }

    private var fill: Color {
        switch window.severity(at: now) {
        case .normal: .primary.opacity(0.55)
        case .warning: Color(SyntaxPalette.warningFill)
        case .critical: Color(SyntaxPalette.criticalFill)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.14))
                Rectangle()
                    .fill(fill)
                    .frame(width: width * (isOvershootOnly ? window.pace(at: now) : window.used))
                if isOvershootOnly {
                    Rectangle()
                        .fill(Color(SyntaxPalette.warningFill).opacity(0.7))
                        .frame(width: width * (window.used - window.pace(at: now)))
                        .offset(x: width * window.pace(at: now))
                }
            }
            .clipShape(.capsule)
            if window.pace(at: now) > 0 {
                Capsule()
                    .fill(.primary)
                    .frame(width: 1.5, height: 10)
                    .offset(x: min(width * window.pace(at: now), width - 1.5))
            }
        }
        .frame(height: 10)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }
}

private struct UsageWindowSection: View {
    let group: UsageGroup
    let window: UsageWindow
    let now: Date
    let showsHarness: Bool

    var body: some View {
        Section {
            UsageTrack(window: window, now: now)
                .listRowSeparator(.hidden)
                .accessibilityHidden(true)
            LabeledContent("Used", value: "\(window.usedPercent)%")
                .foregroundStyle(UsageTrack.aheadTint(window, now: now) ?? .primary)
            LabeledContent("Pace", value: window.pace(at: now).formatted(.wholePercent))
            LabeledContent("Resets", value: window.resetsAt?.formatted(date: .abbreviated, time: .shortened) ?? "When next used")
        } header: {
            Text(showsHarness ? "\(group.name) \(window.title)" : window.title)
        } footer: {
            if let staleSince = group.staleSince {
                Text("Last reported \(staleSince.formatted(.relative(presentation: .named))).")
            }
        }
        .opacity(group.staleSince == nil ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(group.spoken(window, at: now))
    }
}

struct UsageSheet: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { timeline in
                let groups = client.usageGroups(at: timeline.date)
                List {
                    ForEach(groups) { group in
                        ForEach(group.windows) { window in
                            UsageWindowSection(group: group, window: window, now: timeline.date, showsHarness: groups.count > 1 || group.kind == .codex)
                        }
                    }
                    Section {} footer: {
                        Text("The line on each bar marks how much of the window has passed. Usage past the line is faster than an even pace.")
                    }
                }
                .overlay {
                    if groups.isEmpty {
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
