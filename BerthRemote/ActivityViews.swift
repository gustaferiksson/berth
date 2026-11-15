import SwiftUI

struct RunningSummary: View {
    let tasks: [RemoteTask]
    let action: () -> Void

    var body: some View {
        let byKind = Dictionary(grouping: tasks, by: \.kind)
        let counts = [(RemoteTask.agent, "agent", "agents"), (RemoteTask.shell, "shell", "shells"), (RemoteTask.monitor, "monitor", "monitors")].compactMap { kind, one, many -> String? in
            guard let count = byKind[kind]?.count else { return nil }
            return "\(count) \(count == 1 ? one : many)"
        }

        Button(action: action) {
            Label(counts.isEmpty ? "\(tasks.count) running" : counts.joined(separator: " · "), systemImage: "gearshape.2")
        }
        .buttonStyle(.plain)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct RunningSheet: View {
    let tasks: [RemoteTask]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(tasks) { task in
                HStack {
                    Label {
                        Text(task.title)
                            .lineLimit(2)
                        Text(task.kind == RemoteTask.agent ? "Subagent" : task.kind == RemoteTask.shell ? "Shell" : task.kind == RemoteTask.monitor ? "Monitor" : "Task")
                    } icon: {
                        Image(systemName: task.kind == RemoteTask.agent ? "person.2" : task.kind == RemoteTask.monitor ? "eye" : "terminal")
                    }
                    Spacer()
                    Text(task.started, style: .timer)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if tasks.isEmpty {
                    ContentUnavailableView("Nothing Running", systemImage: "checkmark.circle", description: Text("Subagents, background shells and monitors show here while they run."))
                }
            }
            .navigationTitle("Running")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ContextSheet: View {
    let context: RemoteContext

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let tokens = context.tokens, let window = context.window {
                        Gauge(value: Double(tokens), in: 0...Double(window)) {
                            Text("Used")
                        } currentValueLabel: {
                            Text((Double(tokens) / Double(window)).formatted(.percent.precision(.fractionLength(0))))
                        }
                        .tint(Double(tokens) / Double(window) > 0.8 ? .orange : .accentColor)
                    }
                    if let tokens = context.tokens {
                        LabeledContent("Tokens", value: tokens.formatted())
                    } else {
                        LabeledContent("Tokens", value: "Known after the next reply")
                    }
                    LabeledContent("Window", value: context.window?.formatted() ?? "Unknown")
                } footer: {
                    Text("The size of Claude’s last request, \(Text(context.date, style: .relative)) ago: system prompt, tools and conversation.")
                }
                Section {
                    LabeledContent("Model", value: context.model)
                    LabeledContent("Compactions", value: context.compactions.formatted())
                    if let lastCompaction = context.lastCompaction {
                        LabeledContent("Last Compacted") {
                            Text(lastCompaction, style: .relative)
                        }
                    }
                }
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
