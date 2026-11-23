import SwiftUI

struct UsageGroup: Identifiable {
    let name: String
    let asset: String
    let windows: [UsageWindow]
    let staleSince: Date?

    var id: String { name }
}

extension RemoteClient {
    func usageGroups(at now: Date) -> [UsageGroup] {
        let claude = usage.map { UsageGroup(name: "Claude", asset: "HarnessClaude", windows: $0.current(at: now), staleSince: nil) }
        let codex = codexUsage.map { UsageGroup(name: "Codex", asset: "HarnessCodex", windows: $0.usage.current(at: now), staleSince: $0.isStale(at: now) ? $0.recordedAt : nil) }
        return [claude, codex].compactMap(\.self).filter { !$0.windows.isEmpty }
    }
}

struct UsageSummary: View {
    @Environment(RemoteClient.self) private var client

    let open: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let groups = client.usageGroups(at: timeline.date)
            if !groups.isEmpty {
                Button(action: open) {
                    VStack(spacing: 14) {
                        ForEach(groups) { group in
                            HStack(spacing: 10) {
                                if groups.count > 1 || group.name == "Codex" {
                                    Image(group.asset)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 16, height: 16)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                VStack(spacing: 10) {
                                    ForEach(group.windows.prefix(2)) { window in
                                        HStack(spacing: 10) {
                                            Text(window.title)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 58, alignment: .leading)
                                            UsageTrack(window: window, now: timeline.date, height: 8)
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
                                }
                            }
                            .opacity(group.staleSince == nil ? 1 : 0.5)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows plan usage")
            }
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
    let height: CGFloat

    @State private var width = 0.0

    static func aheadTint(_ window: UsageWindow, now: Date) -> Color? {
        guard window.isAhead(at: now) else { return nil }

        return window.severity(at: now) == .critical ? .red : .orange
    }

    private var isOvershootOnly: Bool {
        window.isAhead(at: now) && window.severity(at: now) == .normal
    }

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
                    .frame(width: width * (isOvershootOnly ? window.pace(at: now) : window.used))
                if isOvershootOnly {
                    Rectangle()
                        .fill(.orange.opacity(0.7))
                        .frame(width: width * (window.used - window.pace(at: now)))
                        .offset(x: width * window.pace(at: now))
                }
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

private struct UsageWindowSection: View {
    let group: UsageGroup
    let window: UsageWindow
    let now: Date
    let showsHarness: Bool

    var body: some View {
        Section {
            UsageTrack(window: window, now: now, height: 10)
                .listRowSeparator(.hidden)
                .accessibilityHidden(true)
            LabeledContent("Used", value: "\(window.usedPercent)%")
                .foregroundStyle(UsageTrack.aheadTint(window, now: now) ?? .primary)
            LabeledContent("Pace", value: window.pace(at: now).formatted(.wholePercent))
            if let resetsAt = window.resetsAt {
                LabeledContent("Resets", value: resetsAt.formatted(date: .abbreviated, time: .shortened))
            }
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
                            UsageWindowSection(group: group, window: window, now: timeline.date, showsHarness: groups.count > 1 || group.name == "Codex")
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
