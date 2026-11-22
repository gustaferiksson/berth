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
    @State private var isDropTargeted = false
    @State private var composerFocus = 0
    @State private var now = Date.now
    @FocusState private var isFocused: Bool

    var body: some View {
        let live = tab.sessionID.flatMap { store.liveBySession[$0] }
        let isWorking = live?.activity == .working
        let waitingFor: String?? = if case let .needsInput(reason)? = live?.activity { .some(reason) } else { nil }
        let since = tab.sessionID.flatMap { store.turnStarts[$0] } ?? model.turns.last?.prompt?.date
        let openCall = model.turns.last?.openCall
        let approval = live.flatMap { $0.status == "waiting" ? PendingApproval.resolve(waitingFor: $0.waitingFor, call: openCall) : nil }
        let waiting = live.flatMap { $0.status == "waiting" ? (waitingFor: $0.waitingFor, since: $0.statusUpdatedAt) : nil }
        let needsTerminal = model.hasLoaded && ConversationFallback.needsTerminal(live: live, call: openCall, tabAge: now.timeIntervalSince(tab.opened), now: now)

        keyboard(transcript(isWorking: isWorking, waitingFor: waitingFor, since: since), approval: approval, waiting: waiting)
            .onChange(of: needsTerminal, initial: true) { if needsTerminal { store.suspendConversation(tab.id) } }
            .task(id: live?.statusUpdatedAt) {
                now = .now
                try? await Task.sleep(for: .seconds(4.5))
                now = .now
                try? await Task.sleep(for: .seconds(5.5))
                now = .now
            }
            .onChange(of: live?.status) { model.refresh() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ConversationBottomBar(
                    model: model,
                    since: since,
                    isWorking: isWorking,
                    isActive: isWorking || waitingFor != nil,
                    isAtBottom: isAtBottom,
                    approval: approval,
                    waiting: waiting,
                    composerFocus: $composerFocus,
                    jump: { _ = scrollToLatest() },
                    answer: { _ = answer($0, waiting) },
                    deny: { _ = deny(waiting) }
                )
            }
            .overlay {
                ConversationDropTarget(isTargeted: $isDropTargeted) { files in
                    model.append(files)
                    composerFocus += 1
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }
                }
            }
            .environment(\.conversationFolder, tab.cwd)
            .accessibilityLabel("Conversation")
    }

    private func transcript(isWorking: Bool, waitingFor: String??, since: Date?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if model.turns.isEmpty {
                    emptyState
                }
                ForEach(model.turns) { turn in
                    let isCurrent = turn.id == model.turns.last?.id
                    ConversationTurnView(
                        turn: turn,
                        isFinished: !(isCurrent && (isWorking || waitingFor != nil)),
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
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 24, for: .scrollContent)
        .contentMargins(.bottom, model.tasks.isEmpty ? 24 : 66, for: .scrollContent)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .onScrollGeometryChange(for: ConversationScrollState.self) { geometry in
            ConversationScrollState(height: geometry.contentSize.height, isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40)
        } action: { old, new in
            if new.height != old.height, isAtBottom { position.scrollTo(edge: .bottom) } else { isAtBottom = new.isAtBottom }
        }
    }

    private func keyboard(_ content: some View, approval: PendingApproval?, waiting: (waitingFor: String?, since: Double?)?) -> some View {
        let isDraftEmpty = model.draft.isEmpty
        let isActionable = approval?.isActionable ?? false

        return content
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.end) { scrollToLatest() }
            .onKeyPress(.home) {
                withAnimation(.smooth) { position.scrollTo(edge: .top) }
                return .handled
            }
            .onKeyPress(.downArrow, phases: .down) { press in press.modifiers == .command ? scrollToLatest() : .ignored }
            .onKeyPress(.return) { isActionable && isDraftEmpty ? answer(.digit1, waiting) : .ignored }
            .onKeyPress(.escape) { isActionable ? deny(waiting) : .ignored }
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                guard case let .question(_, options)? = approval, isDraftEmpty, let digit = Int(press.characters), (1...options.count).contains(digit) else { return .ignored }

                return answer(RemoteKey(rawValue: "digit\(digit)") ?? .digit1, waiting)
            }
            .onKeyPress(phases: [.down, .repeat]) { press in
                let scalars = press.characters.unicodeScalars
                guard press.modifiers.isSubset(of: .shift), !scalars.isEmpty, scalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) else { return .ignored }

                model.draft.text += press.characters
                composerFocus += 1
                return .handled
            }
            .onChange(of: store.conversationFocusRequests, initial: true) {
                if isActionable, isDraftEmpty { isFocused = true } else { composerFocus += 1 }
            }
            .onChange(of: isActionable) {
                if isActionable, isDraftEmpty { isFocused = true } else if !isActionable { composerFocus += 1 }
            }
    }

    private var emptyState: some View {
        Group {
            if model.hasLoaded {
                ContentUnavailableView("No Messages Yet", systemImage: "text.bubble", description: Text("The conversation appears here once this session has a prompt."))
            } else {
                ConversationSpinner()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 80)
    }

    private func answer(_ key: RemoteKey, _ waiting: (waitingFor: String?, since: Double?)?) -> KeyPress.Result {
        guard let waiting else { return .ignored }

        model.answer(key, waitingFor: waiting.waitingFor, since: waiting.since)
        return .handled
    }

    private func deny(_ waiting: (waitingFor: String?, since: Double?)?) -> KeyPress.Result {
        guard let waiting else { return .ignored }

        model.answer(.escape, waitingFor: waiting.waitingFor, since: waiting.since)
        composerFocus += 1
        return .handled
    }

    private func scrollToLatest() -> KeyPress.Result {
        withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(edge: .bottom) }
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
        let workCount = turn.parts.count { $0.isWork }
        let lastIndex = turn.parts.count - 1

        VStack(alignment: .leading, spacing: 14) {
            if let prompt = turn.prompt {
                ConversationPrompt(entry: prompt)
            }
            ForEach(turn.parts.enumerated(), id: \.element.id) { index, part in
                if case let .work(calls) = part, !turn.isInterrupted, isFinished || index < lastIndex {
                    ConversationFold(label: isFinished && workCount == 1 ? turn.duration.map { "Worked for \($0.formatted(elapsedFormat))" } ?? "Worked" : ToolCall.summary(of: calls)) {
                        ConversationPartView(part: part, tasks: tasks, openCall: nil, isWaiting: false)
                    }
                } else {
                    ConversationPartView(part: part, tasks: tasks, openCall: isFinished ? nil : turn.openCall, isWaiting: waitingFor != nil)
                }
            }
            if isFinished, !turn.isInterrupted, let changes = turn.fileChanges {
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

    private var working: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .accessibilityHidden(true)
            } else {
                ConversationSpinner()
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
    let tasks: [RemoteTask]
    let isAtBottom: Bool
    let jump: () -> Void

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsTasks = conversationShowsTasks
    private let pillTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.92))

    var body: some View {
        let kinds = [RemoteTask.agent, RemoteTask.shell, RemoteTask.monitor].filter { kind in tasks.contains { $0.kind == kind } }

        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if isWorking, !isAtBottom {
                    HStack(spacing: 8) {
                        if reduceMotion {
                            Image(systemName: "hourglass")
                                .accessibilityHidden(true)
                        } else {
                            ConversationSpinner()
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
                    .transition(pillTransition)
                }
                if !tasks.isEmpty {
                    Button { showsTasks.toggle() } label: {
                        HStack(spacing: 8) {
                            ForEach(kinds, id: \.self) { kind in
                                Image(systemName: RemoteTask(id: "", kind: kind, title: "", started: .now).symbol)
                                    .accessibilityHidden(true)
                            }
                            Text(RemoteTask.summary(of: tasks))
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .popover(isPresented: $showsTasks, arrowEdge: .top) { ConversationTaskList(tasks: tasks) }
                    .accessibilityValue(showsTasks ? "Expanded" : "Collapsed")
                }
                if !isAtBottom {
                    Button(action: jump) {
                        Image(systemName: "arrow.down")
                            .frame(width: 15, height: 15)
                            .padding(8)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Jump to Latest")
                    .help("Jump to Latest (⌘↓)")
                    .transition(pillTransition)
                }
            }
        }
        .font(.subheadline)
        .animation(.easeOut(duration: 0.15), value: isAtBottom)
        .animation(.easeOut(duration: 0.15), value: isWorking)
        .animation(.easeOut(duration: 0.15), value: tasks.isEmpty)
        .onChange(of: tasks.isEmpty) { if tasks.isEmpty { showsTasks = false } }
    }
}

private struct ConversationTaskList: View {
    let tasks: [RemoteTask]

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(tasks) { task in
                HStack(spacing: 10) {
                    Image(systemName: task.symbol)
                        .foregroundStyle(theme.secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: task.title)
                            .lineLimit(1)
                        Text(verbatim: task.agentType ?? task.kindName)
                            .font(.caption)
                            .foregroundStyle(theme.secondary)
                    }
                    Spacer(minLength: 12)
                    ConversationElapsed(since: task.started)
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

private extension PendingApproval {
    var isActionable: Bool {
        switch self {
        case .permission, .question, .plan: true
        case .loading, .unrepresentable: false
        }
    }
}

private struct ConversationBottomBar: View {
    let model: ConversationModel
    let since: Date?
    let isWorking: Bool
    let isActive: Bool
    let isAtBottom: Bool
    let approval: PendingApproval?
    let waiting: (waitingFor: String?, since: Double?)?
    @Binding var composerFocus: Int
    let jump: () -> Void
    let answer: (RemoteKey) -> Void
    let deny: () -> Void

    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            if let approval, approval.isActionable || approval == .loading {
                ConversationApprovalCard(
                    approval: approval,
                    since: waiting?.since.map { Date(timeIntervalSince1970: $0 / 1000) },
                    answer: answer,
                    deny: deny,
                    declineWithMessage: { composerFocus += 1 },
                    showTerminal: { AppAction.showTerminal.perform(on: store) }
                )
                .transition(.blurReplace)
            }
            ConversationComposer(model: model, isWorking: isWorking, waiting: waiting, context: model.context, focusRequest: composerFocus)
        }
        .frame(maxWidth: 860)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            ConversationStatusBar(since: since, isWorking: isWorking, tasks: model.tasks, isAtBottom: isAtBottom, jump: jump)
                .alignmentGuide(.top) { $0[.bottom] + 10 }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: isActive)
        .animation(.smooth, value: approval)
    }
}
