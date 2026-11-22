import BerthCore
import SwiftUI

struct ConversationView: View {
    let model: ConversationModel
    let tab: Tab

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @AppStorage(GeneralSettings.reviewKey) private var isReviewEnabled = false
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @FocusState private var isFocused: Bool

    var body: some View {
        let live = tab.sessionID.flatMap { store.liveBySession[$0] }
        let isWorking = live?.activity == .working
        let waitingFor: String?? = if case let .needsInput(reason)? = live?.activity { .some(reason) } else { nil }
        let isActive = isWorking || waitingFor != nil
        let since = tab.sessionID.flatMap { store.turnStarts[$0] } ?? model.turns.last?.prompt?.date

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if model.turns.isEmpty {
                    emptyState
                }
                ForEach(model.turns) { turn in
                    let isCurrent = turn.id == model.turns.last?.id
                    ConversationTurnView(
                        turn: turn,
                        isFinished: !(isCurrent && isActive),
                        isWorking: isCurrent && isWorking,
                        waitingFor: isCurrent ? waitingFor : nil,
                        since: since,
                        tasks: model.tasks,
                        reviewChanges: isReviewEnabled ? { AppAction.showChanges.perform(on: store) } : nil
                    )
                }
                ForEach(model.queued, id: \.self) { prompt in
                    ConversationPrompt(entry: RemoteEntry(id: prompt, kind: .prompt, text: prompt), isQueued: true)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 24, for: .scrollContent)
        .contentMargins(.bottom, 96, for: .scrollContent)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onScrollGeometryChange(for: ConversationScrollState.self) { geometry in
            ConversationScrollState(height: geometry.contentSize.height, isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40)
        } action: { old, new in
            if new.height != old.height, isAtBottom { position.scrollTo(edge: .bottom) } else { isAtBottom = new.isAtBottom }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.end) { scrollToLatest() }
        .onKeyPress(.home) {
            withAnimation(.smooth) { position.scrollTo(edge: .top) }
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in press.modifiers == .command ? scrollToLatest() : .ignored }
        .onChange(of: store.conversationFocusRequests, initial: true) { isFocused = true }
        .onChange(of: live?.status) { model.refresh() }
        .overlay(alignment: .bottom) {
            ConversationStatusBar(
                since: since,
                isWorking: isWorking,
                waitingFor: waitingFor,
                tasks: model.tasks,
                isAtBottom: isAtBottom,
                jump: { _ = scrollToLatest() },
                showTerminal: { AppAction.showTerminal.perform(on: store) }
            )
            .padding(.bottom, 16)
            .animation(.smooth, value: isAtBottom)
            .animation(.smooth, value: model.tasks.count)
            .animation(.smooth, value: isActive)
        }
        .environment(\.conversationFolder, tab.cwd)
        .accessibilityLabel("Conversation")
    }

    private var emptyState: some View {
        Group {
            if model.hasLoaded {
                ContentUnavailableView("No Messages Yet", systemImage: "text.bubble", description: Text("The conversation appears here once this session has a prompt."))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 80)
    }

    private func scrollToLatest() -> KeyPress.Result {
        withAnimation(.smooth) { position.scrollTo(edge: .bottom) }
        isAtBottom = true
        return .handled
    }
}

private struct ConversationScrollState: Equatable {
    let height: Double
    let isAtBottom: Bool
}

private struct ConversationTurnView: View {
    let turn: Turn
    let isFinished: Bool
    let isWorking: Bool
    let waitingFor: String??
    let since: Date?
    let tasks: [RemoteTask]
    let reviewChanges: (() -> Void)?

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lastWork = turn.parts.lastIndex { if case .work = $0 { true } else { false } }
        let folded = isFinished && !turn.isInterrupted ? lastWork.map { turn.parts[...$0] } : nil
        let foldedCards = folded?.flatMap { part -> [ToolCall] in
            guard case let .cards(calls) = part else { return [] }

            return calls
        } ?? []

        VStack(alignment: .leading, spacing: 14) {
            if let prompt = turn.prompt {
                ConversationPrompt(entry: prompt)
            }
            if let folded {
                ConversationFold(label: turn.duration.map { "Worked for \($0.formatted(elapsedFormat))" } ?? "Worked") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(folded.filter { !$0.isCards }) { part in
                            ConversationPartView(part: part, tasks: tasks, openCall: nil, isWaiting: false)
                        }
                    }
                }
            }
            ForEach(foldedCards) { call in
                ConversationTaskRow(call: call, task: task(for: call))
                    .padding(.leading, 24)
            }
            ForEach(turn.parts[(folded?.endIndex ?? 0)...]) { part in
                ConversationPartView(part: part, tasks: tasks, openCall: isFinished ? nil : turn.openCall, isWaiting: waitingFor != nil)
            }
            if folded != nil, let changes = turn.fileChanges {
                changedFiles(changes)
            }
            if turn.isInterrupted {
                Label("Interrupted", systemImage: "stop.circle")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondary)
            }
            if isWorking {
                working
            }
        }
    }

    private func task(for call: ToolCall) -> RemoteTask? {
        tasks.first { $0.id == call.use.toolID || (call.use.date != nil && $0.started == call.use.date && $0.title == call.cardTitle) }
    }

    private var working: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text("Working")
            if let since {
                Text(verbatim: "·")
                ConversationElapsed(since: since)
            }
        }
        .font(.subheadline)
        .foregroundStyle(theme.secondary)
        .padding(.leading, 2)
    }

    private func changedFiles(_ changes: FileChanges) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.forwardslash.minus")
                .accessibilityHidden(true)
                .foregroundStyle(theme.secondary)
            Text("\(changes.files) changed \(changes.files == 1 ? "file" : "files")")
            if let added = changes.added, let removed = changes.removed {
                Text(verbatim: "+\(added)")
                    .foregroundStyle(theme.working)
                Text(verbatim: "−\(removed)")
                    .foregroundStyle(theme.closed)
            }
            if let reviewChanges {
                Button("Review Changes", action: reviewChanges)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .font(.subheadline.monospacedDigit())
        .padding(.leading, 2)
    }
}

private struct ConversationPartView: View {
    let part: TurnPart
    let tasks: [RemoteTask]
    let openCall: ToolCall?
    let isWaiting: Bool

    var body: some View {
        switch part {
        case let .reply(entry):
            ConversationReply(text: entry.text)

        case let .work(calls):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(calls) { call in
                    ConversationToolRow(call: call, state: call.id == openCall?.id ? (isWaiting ? .waiting : .running) : .finished)
                }
            }

        case let .cards(calls):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(calls) { call in
                    ConversationTaskRow(call: call, task: tasks.first { $0.id == call.use.toolID || (call.use.date != nil && $0.started == call.use.date && $0.title == call.cardTitle) })
                }
            }
            .padding(.leading, 24)
        }
    }
}

private struct ConversationFold<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    @Environment(\.ghosttyTheme) private var theme
    @State private var isExpanded = conversationExpandsAll
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: "✻")
                        .accessibilityHidden(true)
                    Text(label)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .font(theme.conversationFont(-1))
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.foreground.opacity(isHovered ? 0.1 : 0.05), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.foreground.opacity(0.14))
                            .frame(width: 1)
                    }
            }
        }
    }
}

private struct ConversationStatusBar: View {
    let since: Date?
    let isWorking: Bool
    let waitingFor: String??
    let tasks: [RemoteTask]
    let isAtBottom: Bool
    let jump: () -> Void
    let showTerminal: () -> Void

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsTasks = false

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if let waitingFor {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised.fill")
                            .accessibilityHidden(true)
                            .foregroundStyle(theme.needsYou)
                        Text(waitingFor.map { "Needs you · \($0)" } ?? "Needs you")
                            .lineLimit(1)
                        Button("Show Terminal", action: showTerminal)
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .tint(theme.needsYou)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.tint(theme.needsYou.opacity(0.18)), in: .capsule)
                } else if isWorking, !isAtBottom {
                    HStack(spacing: 8) {
                        if reduceMotion {
                            Image(systemName: "hourglass")
                                .accessibilityHidden(true)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Working")
                        if let since {
                            Text(verbatim: "·")
                            ConversationElapsed(since: since)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(in: .capsule)
                }
                if !tasks.isEmpty {
                    Button { showsTasks = true } label: {
                        Label("\(tasks.count) running", systemImage: "person.2")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .popover(isPresented: $showsTasks, arrowEdge: .top) { ConversationTasksPopover(tasks: tasks) }
                }
                if !isAtBottom {
                    Button("Jump to Latest", systemImage: "arrow.down", action: jump)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("Jump to Latest (⌘↓)")
                }
            }
        }
        .font(.subheadline)
    }
}

private struct ConversationTasksPopover: View {
    let tasks: [RemoteTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(tasks) { task in
                HStack(spacing: 10) {
                    Image(systemName: task.kind == RemoteTask.shell ? "terminal" : "person.2")
                        .accessibilityHidden(true)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: task.title)
                            .lineLimit(2)
                        HStack(spacing: 4) {
                            Text(verbatim: task.agentType ?? (task.kind == RemoteTask.shell ? "Shell" : "Agent"))
                            Text(verbatim: "·")
                            ConversationElapsed(since: task.started)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}
