import SwiftUI

private extension RemoteTask {
    var symbol: String {
        kind == Self.agent ? "person.2" : kind == Self.monitor ? "eye" : "terminal"
    }

    var kindName: String {
        kind == Self.agent ? "Agent" : kind == Self.shell ? "Shell" : kind == Self.monitor ? "Monitor" : "Task"
    }

    var stats: Text? {
        guard let toolCount else { return nil }

        let tokenText = tokens.map { Text(verbatim: $0.formatted(.number.notation(.compactName))).monospaced() }
        return Text("\(Text(toolCount.formatted()).monospaced()) tool \(toolCount == 1 ? "use" : "uses")\(tokenText.map { Text(" · \($0) tokens") } ?? Text(verbatim: ""))")
    }
}

struct RunningStrip: View {
    let tasks: [RemoteTask]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tasks.prefix(3)) { task in
                        HStack(spacing: 8) {
                            Image(systemName: task.symbol)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 0) {
                                title(task)
                                    .lineLimit(1)
                                Text("\(task.agentType ?? task.kindName) · \(Text(task.started, style: .timer).monospacedDigit())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if tasks.count > 3 {
                        Text("+\(tasks.count - 3) more")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityHint("Shows what is running")
    }

    @ViewBuilder
    private func title(_ task: RemoteTask) -> some View {
        if task.kind == RemoteTask.shell {
            Text(verbatim: task.command ?? task.title)
                .monospaced()
        } else {
            Text(task.title)
        }
    }
}

struct RunningSheet: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var path = [UserDefaults.standard.string(forKey: "snapshotRunningTask")].compactMap(\.self)

    var body: some View {
        let tasks = client.activity[sessionID]?.tasks ?? []

        NavigationStack(path: $path) {
            List(tasks) { task in
                NavigationLink(value: task.id) {
                    TaskRow(task: task)
                }
            }
            .overlay {
                if tasks.isEmpty {
                    ContentUnavailableView("Nothing Running", systemImage: "checkmark.circle", description: Text("Subagents, background shells and monitors show here while they run."))
                }
            }
            .navigationTitle("Running")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { taskID in
                TaskDetailView(sessionID: sessionID, taskID: taskID)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct TaskRow: View {
    let task: RemoteTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: task.symbol)
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityLabel(task.kindName)
            VStack(alignment: .leading, spacing: 2) {
                if task.command == task.title {
                    Text(verbatim: task.title)
                        .monospaced()
                        .lineLimit(2)
                } else {
                    Text(task.title)
                        .lineLimit(2)
                }
                if let command = task.command, command != task.title {
                    Text(verbatim: command)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if task.kind == RemoteTask.agent {
                    Text("\(Text(task.agentType ?? "Subagent"))\(task.stats.map { Text(" · \($0)") } ?? Text(verbatim: ""))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let call = task.call {
                        Text(call.phrase)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(task.started, style: .timer)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ScrollExtent: Equatable {
    let isAtBottom: Bool
    let height: Double
}

private struct TaskDetailView: View {
    let sessionID: String
    let taskID: String

    @Environment(RemoteClient.self) private var client

    var body: some View {
        let task = client.activity[sessionID]?.tasks.first { $0.id == taskID }
        let detail = client.taskDetails[taskID]
        let canFetch = client.features.contains(RemoteTaskDetail.feature)

        ScrollViewReader { proxy in
            List {
                if let task {
                    Section {
                        LabeledContent("Running for") {
                            Text(task.started, style: .timer)
                                .monospacedDigit()
                        }
                        if task.command != task.title {
                            Text(task.title)
                        }
                        if let agentType = task.agentType {
                            LabeledContent("Type", value: agentType)
                        }
                        if let stats = task.stats {
                            LabeledContent("Activity") { stats }
                        }
                    }
                    if let command = task.command {
                        Section("Command") {
                            Text(verbatim: command)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Label("Finished", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if task?.kind == RemoteTask.agent || task == nil, let calls = detail?.calls {
                    Section("Recent Tool Calls") {
                        ForEach(calls.reversed().enumerated(), id: \.offset) { _, call in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: call.name)
                                    .font(.footnote.bold().monospaced())
                                Text(verbatim: call.summary)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
                if task?.kind == RemoteTask.shell || (task == nil && detail?.output != nil) {
                    Section {
                        Text(verbatim: detail?.output?.isEmpty == false ? detail?.output ?? "" : "No output yet")
                            .font(.caption.monospaced())
                            .foregroundStyle(detail?.output?.isEmpty == false ? .primary : .secondary)
                            .textSelection(.enabled)
                    } header: {
                        Text("Output")
                    } footer: {
                        Text(canFetch ? "The last 50 lines, updated while this is open." : "Update Berth on your Mac to see output.")
                    }
                }
                Color.clear
                    .frame(height: 1)
                    .listRowBackground(Color.clear)
                    .id("end")
            }
            .onScrollGeometryChange(for: ScrollExtent.self) { ScrollExtent(isAtBottom: $0.visibleRect.maxY >= $0.contentSize.height - 40, height: $0.contentSize.height) } action: { old, new in
                guard old.isAtBottom, new.height > old.height else { return }

                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        .navigationTitle(task?.kindName ?? "Finished")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled, task?.kind != RemoteTask.monitor {
                client.requestTaskDetail(taskID, in: sessionID)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct ContextRing: View {
    let context: RemoteContext?

    var body: some View {
        let fill = context?.tokens.flatMap { tokens in context?.window.map { Double(tokens) / Double($0) } }
        let level = fill ?? 0
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(level, 1))
                .stroke(level >= 0.9 ? .red : level >= 0.7 ? .orange : .primary, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
        .frame(width: 20, height: 20)
        .accessibilityLabel(fill.map { "Context \($0.formatted(.percent.precision(.fractionLength(0)))) full" } ?? "Context")
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
                        .tint(Double(tokens) / Double(window) >= 0.9 ? .red : Double(tokens) / Double(window) >= 0.7 ? .orange : .accentColor)
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
