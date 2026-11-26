import AppKit
import BerthCore
import GhosttyTerminal
import SwiftUI

struct BackgroundTaskSidebar: View {
    let store: Store
    @Environment(\.ghosttyTheme) private var theme
    @State private var showsRunning = true
    @State private var showsFinished = true

    var body: some View {
        let tasks = store.backgroundTasks
        let groups = BackgroundTaskGroups(tasks)
        let selection = Binding(get: { store.selectedBackgroundTask(in: tasks)?.id }, set: { id in
            if let tab = store.sessionTab, let id { store.selectedBackgroundTaskIDs[tab.id] = id }
        })
        List(selection: selection) {
            if !groups.running.isEmpty {
                SidebarSection(title: "Running", help: "Show or hide running tasks", count: groups.running.count, isExpanded: $showsRunning) {
                    rows(groups.running)
                }
            }
            if !groups.finished.isEmpty {
                SidebarSection(title: "Finished", help: "Show or hide finished tasks", count: groups.finished.count, isExpanded: $showsFinished) {
                    rows(groups.finished)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Background Tasks")
    }

    private func rows(_ tasks: [SessionBackgroundTask]) -> some View {
        ForEach(tasks) { task in
            let stop = store.subagentStop(for: task)
            HStack(spacing: 9) {
                Image(systemName: task.symbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, height: 25)
                    .background(.primary.opacity(0.07), in: .rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: task.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(2)
                    TaskStatusLine(task: task)
                }
                Spacer(minLength: 4)
                if task.status == .running { TaskWorkingIndicator() }
                if let stop {
                    Button(stop.title, systemImage: "stop.fill") { store.stopSubagent(task) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(stop.title)
                }
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: stop == nil ? .combine : .contain)
            .listRowSeparator(.hidden)
            .tag(task.id)
            .contextMenu {
                if store.canStop(task) { Button("Stop Shell", systemImage: "stop.fill") { store.stopBackgroundTask(task.id) } }
                if let stop { Button(stop.title, systemImage: "stop.fill") { store.stopSubagent(task) } }
            }
        }
    }
}

struct BackgroundTaskPane: View {
    let store: Store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if let task = store.selectedBackgroundTask(in: store.backgroundTasks) {
                BackgroundTaskDetail(store: store, task: task)
                    .id(task.id)
            } else {
                ContentUnavailableView("No Background Tasks", systemImage: AppAction.showTasksPane.symbol)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.foreground)
        .background(theme.background ?? Color(nsColor: .textBackgroundColor))
        .overlay { CardBorder() }
    }
}

private struct BackgroundTaskDetail: View {
    let store: Store
    let task: SessionBackgroundTask
    @Environment(\.ghosttyTheme) private var theme
    @State private var fileOutput: String?
    @State private var agent: ConversationSubagentModel?
    @State private var showsTranscript = false

    private var terminalID: Tab.ID? {
        guard task.kind == .terminal, task.status == .running, let id = UUID(uuidString: task.id), let parent = store.sessionTab?.id,
              store.tabs.contains(where: { $0.id == id && $0.parentTabID == parent }) else { return nil }

        return id
    }

    private var output: String {
        if let fileOutput, !fileOutput.isEmpty { return fileOutput }
        if task.kind != .agent { return task.result ?? "" }

        let replies = agent?.turns.flatMap(\.parts).compactMap { part -> String? in
            if case let .reply(entry) = part { return entry.text }
            return nil
        }.joined(separator: "\n\n")
        let prompt = task.prompt ?? agent?.turns.first?.prompt?.text
        return [prompt, replies.flatMap { $0.isEmpty ? nil : $0 } ?? task.result]
            .compactMap(\.self)
            .joined(separator: "\n\n")
    }

    var body: some View {
        let output = output
        VStack(spacing: 0) {
            header(output: output)
            Hairline(axis: .horizontal)
            Group {
                if showsTranscript, let agent {
                    ConversationSubagentTranscript(model: agent, isFinished: task.status != .running)
                        .conversationTypography()
                        .environment(\.conversationFolder, store.sessionTab?.folder ?? "")
                } else if task.kind == .terminal {
                    ContentUnavailableView(
                        terminalID == nil ? "Terminal Closed" : "Output in Terminal",
                        systemImage: task.symbol,
                        description: terminalID == nil ? nil : Text("Open this terminal to see its live output.")
                    )
                } else if output.isEmpty {
                    ContentUnavailableView(task.status == .running ? "Waiting for Output" : "No Output Available", systemImage: "text.alignleft")
                } else {
                    ScrollView {
                        Text(verbatim: output)
                            .font(Font(theme.font))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    .modifier(FollowsLatestOutput())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: task) { await loadOutput() }
        .onDisappear { agent?.stop() }
    }

    private func header(output: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: task.symbol)
                .foregroundStyle(theme.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: task.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .help(task.title)
                TaskStatusLine(task: task, showsRunningLabel: true)
            }
            Spacer(minLength: 4)
            if let terminalID {
                action("Stop Terminal", symbol: "stop.fill") { store.close(terminalID, stopsTask: true) }
                action("Open Terminal", symbol: "arrow.up.right") { store.activate(.tab(terminalID)) }
            }
            if store.canStop(task) {
                action("Stop Shell", symbol: "stop.fill") { store.stopBackgroundTask(task.id) }
            }
            if let stop = store.subagentStop(for: task) {
                action(stop.title, symbol: "stop.fill") { store.stopSubagent(task) }
            }
            if agent != nil {
                action(showsTranscript ? "Show Text Output" : "Open Transcript", symbol: showsTranscript ? "text.alignleft" : "doc.text") {
                    showsTranscript.toggle()
                }
            }
            if let terminalID, let terminal = store.tabs.first(where: { $0.id == terminalID })?.terminal {
                action("Copy Output", symbol: "document.on.document") {
                    guard terminal.performBindingAction("select_all") else { return }

                    terminal.performBindingAction("copy_to_clipboard")
                    terminal.performBindingAction("clear_selection")
                }
            } else if task.kind != .terminal {
                action("Copy Output", symbol: "document.on.document") { copyToPasteboard(output) }
                    .disabled(output.isEmpty)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(theme.foreground.opacity(0.035))
    }

    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .help(title)
    }

    private func loadOutput() async {
        let file = task.outputFile
        let source = store.backgroundTaskSource
        let agentID = task.agentID
        let toolUseID = task.toolUseID
        repeat {
            let needsTranscript = task.kind == .agent && agent == nil
            let (output, subagent) = await Task.detached {
                let output = file.flatMap { TaskOutput.tail($0, maxBytes: 64 << 10, maxLines: 500) }
                let subagent = needsTranscript ? source.flatMap { $0.agent.harness.locateSubagent($0.root, $0.transcript, agentID, toolUseID) } : nil
                return (output, subagent)
            }.value
            guard !Task.isCancelled else { return }

            if fileOutput != output { fileOutput = output }
            if let subagent, let source {
                let model = ConversationSubagentModel(subagent: subagent, root: source.root, session: source.transcript, harness: source.agent.harness)
                model.start()
                agent = model
            }
            guard task.status == .running, file != nil || needsTranscript && agent == nil else { return }

            try? await Task.sleep(for: .milliseconds(600))
        } while !Task.isCancelled
    }
}

private struct TaskWorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if reduceMotion {
                Circle().fill().frame(width: 6, height: 6)
            } else {
                ConversationSpinner()
                    .scaleEffect(0.7)
            }
        }
        .frame(width: 14, height: 14)
        .foregroundStyle(theme.working)
        .accessibilityHidden(true)
    }
}

private struct TaskStatusLine: View {
    let task: SessionBackgroundTask
    var showsRunningLabel = false
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        Group {
            if task.status == .running {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let elapsed = task.elapsed(at: timeline.date).formatted(elapsedFormat)
                    Text(verbatim: "\(task.kindName) · \(showsRunningLabel ? "Running · " : "")\(elapsed)")
                        .accessibilityLabel("\(task.kindName), running for \(elapsed)")
                }
            } else {
                Text("\(task.kindName) · \(task.status.title)")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(theme.foreground.opacity(0.75))
        .lineLimit(1)
    }
}

struct FollowsLatestOutput: ViewModifier {
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ConversationScrollState.self) { geometry in
                ConversationScrollState(height: geometry.contentSize.height, isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 12)
            } action: { old, new in
                if old.height != new.height, isAtBottom { position.scrollTo(edge: .bottom) } else { isAtBottom = new.isAtBottom }
            }
    }
}

private extension SessionBackgroundTask {
    var symbol: String {
        switch kind {
        case .shell: "terminal"
        case .agent: "person.2"
        case .terminal: "apple.terminal"
        case .monitor: "eye"
        }
    }

    var kindName: String {
        switch kind {
        case .shell: "Background shell"
        case .agent: "Subagent"
        case .terminal: "Terminal"
        case .monitor: "Monitor"
        }
    }
}

private extension SessionBackgroundTask.Status {
    var title: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .finished: "Finished"
        case let .exit(code): "Exit \(code)"
        }
    }
}
