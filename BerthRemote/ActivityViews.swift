import SwiftUI

extension RemoteTask {
    var stats: Text? {
        guard let toolCount else { return nil }

        let tokenText = tokens.map { Text(verbatim: $0.formatted(.number.notation(.compactName))).monospaced() }
        return Text("\(Text(toolCount.formatted()).monospaced()) tool \(toolCount == 1 ? "use" : "uses")\(tokenText.map { Text(" · \($0) tokens") } ?? Text(verbatim: ""))")
    }
}

struct RunningStrip: View {
    let tasks: [RemoteTask]
    let action: () -> Void

    private var summary: String { RemoteTask.summary(of: tasks) }

    var body: some View {
        let kinds = [RemoteTask.agent, RemoteTask.shell, RemoteTask.monitor].filter { kind in tasks.contains { $0.kind == kind } }
        let newest = tasks.max { $0.started < $1.started }
        let oldest = tasks.min { $0.started < $1.started }

        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(kinds.enumerated(), id: \.offset) { _, kind in
                        Image(systemName: RemoteTask(id: "", kind: kind, title: "", started: .now).symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 26, height: 26)
                            .background(.fill.tertiary, in: .circle)
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary)
                        .font(.footnote.weight(.semibold))
                    if let newest {
                        Text(newest.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let oldest {
                    ElapsedText(since: oldest.started)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.capsule)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Running, \(summary)")
        .accessibilityHint("Shows what is running")
    }
}

struct RunningSheet: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String]
    @State private var detent = PresentationDetent.medium

    init(sessionID: String, taskID: String? = nil) {
        self.sessionID = sessionID
        let initial = [taskID ?? UserDefaults.standard.string(forKey: "snapshotRunningTask")].compactMap(\.self)
        _path = State(initialValue: initial)
        _detent = State(initialValue: initial.isEmpty ? .medium : .large)
    }

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
        .presentationDetents([.medium, .large], selection: $detent)
        .onChange(of: path.isEmpty) { _, isEmpty in
            if !isEmpty { detent = .large }
        }
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
            ElapsedText(since: task.started)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct ScrollExtent: Equatable {
    let isAtBottom: Bool
    let height: Double
    let overflows: Bool
}

private struct ToolRow: Identifiable {
    let id: String
    let call: RemoteToolCall

    var kind: ToolKind { ToolKind(name: call.name) }

    func phrase(isLive: Bool) -> String {
        if call.name == "Poll" { return isLive ? "Waiting" : "Waited" }
        if call.name == "REPL" { return call.summary.isEmpty ? (isLive ? "Running a script" : "Ran a script") : call.summary }

        let verb = switch call.name {
        case "Write": isLive ? "Writing" : "Wrote"
        case "WebSearch": isLive ? "Searching the web for" : "Searched the web for"
        case "WebFetch": isLive ? "Fetching" : "Fetched"
        default: isLive ? kind.verb.present : kind.verb.past
        }
        return [verb, subject].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var subject: String {
        switch kind {
        case .read, .edit: call.summary.hasPrefix("/") ? URL(filePath: call.summary).lastPathComponent : call.summary
        case .web where call.name == "WebFetch": URL(string: call.summary)?.host() ?? call.summary
        case .other: call.name.components(separatedBy: "__").last ?? ""
        case .todo: ""
        default: call.summary
        }
    }

    var icon: String {
        call.name == "Poll" ? "hourglass" : call.name == "REPL" ? "curlybraces" : kind.icon
    }

    static func rows(_ calls: [RemoteToolCall]) -> [Self] {
        var counts: [String: Int] = [:]
        return calls.map { call in
            let key = "\(call.date?.timeIntervalSince1970 ?? 0)\(call.name)\(call.summary)"
            counts[key, default: 0] += 1
            return Self(id: "\(key)#\(counts[key] ?? 0)", call: call)
        }
    }
}

private struct ToolRowView: View {
    let row: ToolRow
    let isLive: Bool
    let isExpanded: Bool

    var body: some View {
        let hasMore = !row.call.summary.isEmpty && row.call.name != "Poll"
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(verbatim: row.phrase(isLive: isLive))
                    .lineLimit(isExpanded ? nil : 1)
            } icon: {
                Image(systemName: row.icon)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            if isExpanded, hasMore {
                Text(verbatim: row.call.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        .accessibilityAddTraits(hasMore ? .isButton : [])
    }
}

private struct TaskDetailView: View {
    let sessionID: String
    let taskID: String

    @Environment(RemoteClient.self) private var client
    @State private var expanded: Set<String> = []

    var body: some View {
        let task = client.activity[sessionID]?.tasks.first { $0.id == taskID }
        let detail = client.taskDetails[taskID]
        let canFetch = client.features.contains(RemoteTaskDetail.feature)
        let rows = ToolRow.rows(detail?.calls ?? [])
        let isShell = task?.kind == RemoteTask.shell || (task == nil && detail?.output != nil)

        ScrollViewReader { proxy in
            List {
                Section {
                    header(task)
                }
                if let task, let command = task.command, command != task.title {
                    Section("Command") {
                        HighlightedText(text: command, language: "bash")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if let reply = detail?.reply {
                    Section("Latest Message") {
                        Text(reply)
                            .textSelection(.enabled)
                    }
                }
                if !isShell, task?.kind != RemoteTask.monitor, detail?.calls != nil {
                    Section("Tool Calls") {
                        ForEach(rows) { row in
                            Button {
                                withAnimation(.snappy) {
                                    if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                                }
                            } label: {
                                ToolRowView(row: row, isLive: task != nil && row.id == rows.last?.id, isExpanded: expanded.contains(row.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if isShell {
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
                    .listRowInsets(.init())
                    .id("end")
            }
            .onScrollGeometryChange(for: ScrollExtent.self) { ScrollExtent(isAtBottom: $0.visibleRect.maxY >= $0.contentSize.height - 40, height: $0.contentSize.height, overflows: $0.contentSize.height > $0.containerSize.height) } action: { old, new in
                guard old.overflows, new.overflows, old.isAtBottom, new.height > old.height else { return }

                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        .navigationTitle(task?.title ?? "Finished")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled, task?.kind != RemoteTask.monitor {
                client.requestTaskDetail(taskID, in: sessionID)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func header(_ task: RemoteTask?) -> some View {
        if let task {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: task.symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 40, height: 40)
                        .background(.tint.opacity(0.15), in: .circle)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.agentType ?? task.kindName)
                            .font(.headline)
                        Label("Running", systemImage: "circle.fill")
                            .labelStyle(StatusLabelStyle())
                    }
                }
                HStack(alignment: .top, spacing: 0) {
                    metric("Time") { ElapsedText(since: task.started) }
                    if let toolCount = task.toolCount {
                        metric(toolCount == 1 ? "Tool Use" : "Tool Uses") { Text(toolCount.formatted()) }
                    }
                    if let tokens = task.tokens {
                        metric("Tokens") { Text(tokens.formatted(.number.notation(.compactName))) }
                    }
                }
            }
            .padding(.vertical, 4)
        } else {
            Label("Finished", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value()
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.caption2)
                .imageScale(.small)
                .foregroundStyle(.green)
            configuration.title
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

extension RemoteContext {
    var fill: Double? {
        tokens.flatMap { tokens in window.map { Double(tokens) / Double($0) } }
    }
}

struct ContextRing: View {
    let context: RemoteContext?

    var body: some View {
        let fill = context?.fill
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
        .accessibilityLabel(fill.map { "Context \($0.formatted(.wholePercent)) full" } ?? "Context")
    }
}

struct ContextSheet: View {
    let context: RemoteContext
    let agentName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let tokens = context.tokens, let window = context.window {
                        Gauge(value: Double(tokens), in: 0...Double(window)) {
                            Text("Used")
                        } currentValueLabel: {
                            Text((Double(tokens) / Double(window)).formatted(.wholePercent))
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
                    Text("The size of \(agentName)’s last request, \(Text(context.date, style: .relative)) ago: system prompt, tools and conversation.")
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
