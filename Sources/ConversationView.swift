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
    @State private var barHeight: CGFloat = 0
    @State private var now = Date.now
    @FocusState private var isFocused: Bool
    @State private var selection: ConversationSelection

    init(model: ConversationModel, tab: Tab) {
        self.model = model
        self.tab = tab
        _selection = State(initialValue: ConversationSelection { [model] in model.turns })
    }

    var body: some View {
        let harness = tab.agent.harness
        let live = tab.sessionID.flatMap { store.liveBySession[$0] }
        let isWorking = live?.activity == .working || model.isTurnOpen && !(live?.reportsWaiting ?? false)
        let waitingFor: String?? = if case let .needsInput(reason)? = live?.activity { .some(reason) } else { nil }
        let since = tab.sessionID.flatMap { store.turnStarts[$0] } ?? model.turns.last?.prompt?.date
        let resolvedApproval = model.approval(for: live, harness: harness)
        let approval = resolvedApproval ?? (waitingFor == nil ? nil : .loading)
        let waiting = live.flatMap { $0.status == "waiting" ? (waitingFor: $0.waitingFor, since: $0.statusUpdatedAt) : nil }
        let showsStart = model.hasLoaded && model.turns.isEmpty && model.queued.isEmpty && model.pending.isEmpty && approval == nil && waiting == nil
        let needsTerminal = (harness.liveSource == .sessionFiles || live != nil) && model.hasLoaded && ConversationFallback.needsTerminal(live: live, approval: resolvedApproval, tabAge: now.timeIntervalSince(tab.opened), now: now)

        let canDeny = harness.approvalKeys.deny == .escape || approval?.isPermission == true
        let denial = canDeny ? waiting : nil

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
            .overlay {
                if !model.hasLoaded {
                    ConversationSpinner()
                        .allowsHitTesting(false)
                } else if showsStart {
                    Text(verbatim: URL(filePath: tab.folder).lastPathComponent)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .padding(.bottom, barHeight)
                        .accessibilityAddTraits(.isHeader)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                ConversationBottomBar(
                    model: model,
                    tab: tab,
                    harness: harness,
                    canAttach: tab.agent.harness.supports(.modelEffortMenu),
                    since: since,
                    isWorking: isWorking,
                    isActive: isWorking || waitingFor != nil,
                    isAtBottom: isAtBottom,
                    approval: approval,
                    waiting: waiting,
                    denial: denial,
                    barHeight: $barHeight,
                    composerFocus: $composerFocus,
                    jump: { _ = scrollToLatest() },
                    answer: { _ = answer($0, waiting) },
                    deny: { _ = deny(denial) }
                )
            }
            .overlay {
                ConversationDropTarget(isTargeted: $isDropTargeted) { files in
                    guard tab.agent.harness.supports(.modelEffortMenu) else { return }

                    model.append(files)
                    composerFocus += 1
                }
                .overlay {
                    if isDropTargeted, tab.agent.harness.supports(.modelEffortMenu) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 12))
                            .allowsHitTesting(false)
                    }
                }
            }
            .disabled(model.openSubagent != nil)
            .accessibilityHidden(model.openSubagent != nil)
            .overlay {
                if let subagent = model.openSubagent {
                    ConversationSubagentView(model: subagent) { model.openSubagent = nil }
                        .id(subagent.subagent.id)
                }
            }
            .environment(\.openAgentConversation, OpenAgentConversation(open: model.openAgent))
            .environment(\.conversationFolder, tab.cwd)
            .environment(\.openURL, OpenURLAction { url in
                store.openLink(url, from: .conversation)
                return .handled
            })
            .environment(\.promptImageLoader, PromptImageLoader { [model] entryID, index in await model.promptImage(entryID: entryID, index: index) })
            .accessibilityLabel("Conversation")
    }

    private func transcript(isWorking: Bool, waitingFor: String??, since: Date?) -> some View {
        let pending = PendingPrompts.unqueued(model.pending, queued: model.queued)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if model.turns.isEmpty {
                    ForEach(model.queued.enumerated(), id: \.offset) { _, prompt in
                        QueuedPrompt(text: prompt)
                    }
                }
                ForEach(model.turns) { turn in
                    let isCurrent = turn.id == model.turns.last?.id
                    ConversationTurnView(
                        turn: turn,
                        isFinished: !(isCurrent && (isWorking || waitingFor != nil)),
                        isWorking: isCurrent && isWorking,
                        agent: tab.agent,
                        waitingFor: isCurrent ? waitingFor : nil,
                        since: since,
                        tasks: model.tasks,
                        details: model.details,
                        queued: isCurrent ? model.queued : [],
                        reviewChanges: isReviewEnabled ? { store.showChanges(opening: $0) } : nil
                    )
                }
                ForEach(pending, id: \.sentAt) { prompt in
                    if let command = prompt.shellCommand {
                        ConversationPrompt(entry: RemoteEntry(id: "", kind: .prompt, text: command, name: "bash", command: command), isShellRunning: true)
                    } else {
                        ConversationPrompt(entry: RemoteEntry(id: "", kind: .prompt, text: prompt.text))
                            .opacity(0.6)
                    }
                }
            }
            .frame(maxWidth: theme.messageWidth, alignment: .leading)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, 24, for: .scrollContent)
        .contentMargins(.bottom, barHeight + (model.tasks.isEmpty ? 16 : 58), for: .scrollContent)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollEdgeEffectHidden(true, for: .bottom)
        .environment(\.conversationSelection, selection)
        .onChange(of: ObjectIdentifier(model)) { selection = ConversationSelection { [model] in model.turns } }
        .onScrollGeometryChange(for: ConversationScrollState.self) { geometry in
            ConversationScrollState(height: geometry.contentSize.height, isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height + geometry.contentInsets.bottom - 40)
        } action: { old, new in
            if new.height != old.height, isAtBottom { position.scrollTo(edge: .bottom) } else { isAtBottom = new.isAtBottom }
        }
    }

    private func keyboard(_ content: some View, approval: PendingApproval?, waiting: (waitingFor: String?, since: Double?)?) -> some View {
        let isDraftEmpty = model.draft.isEmpty
        let isActionable = approval?.isActionable ?? false
        let keys = tab.agent.harness.approvalKeys
        let canDeny = keys.deny == .escape || approval?.isPermission == true

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
            .onKeyPress(.return) { isActionable && isDraftEmpty ? answer(keys.approve, waiting) : .ignored }
            .onKeyPress(.escape) { isActionable && canDeny ? deny(waiting) : .ignored }
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

private struct QueuedPrompt: View {
    let text: String

    var body: some View {
        ConversationPrompt(entry: RemoteEntry(id: text, kind: .prompt, text: text))
            .opacity(0.5)
    }
}

struct ConversationScrollState: Equatable {
    let height: Double
    let isAtBottom: Bool
}

struct ConversationTurnView: View {
    let turn: Turn
    let isFinished: Bool
    let isWorking: Bool
    let agent: Agent
    let waitingFor: String??
    let since: Date?
    let tasks: [RemoteTask]
    let details: [String: ToolCallDetails]
    var queued: [String] = []
    let reviewChanges: (([String]) -> Void)?

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let workCount = turn.parts.count { $0.isWork }
        let openCall = isFinished ? nil : turn.openCall

        VStack(alignment: .leading, spacing: 14) {
            if let prompt = turn.prompt {
                ConversationPrompt(entry: prompt, selectionID: "prompt:\(turn.id)", isShellRunning: turn.parts.isEmpty)
            }
            ForEach(turn.parts) { part in
                if case let .work(calls) = part, !turn.isInterrupted {
                    let live = calls.last.flatMap { $0.id == openCall?.id ? $0 : nil }
                    ConversationFold(label: foldLabel(calls: calls, live: live, workCount: workCount), state: live == nil ? .finished : waitingFor != nil ? .waiting : .running) {
                        ConversationPartView(part: part, tasks: tasks, details: details, openCall: openCall, isWaiting: waitingFor != nil)
                    }
                } else {
                    ConversationPartView(part: part, tasks: tasks, details: details, openCall: openCall, isWaiting: waitingFor != nil)
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
            ForEach(queued.enumerated(), id: \.offset) { _, prompt in
                QueuedPrompt(text: prompt)
            }
            if isWorking {
                working
            }
        }
    }

    private func foldLabel(calls: [ToolCall], live: ToolCall?, workCount: Int) -> String {
        if let live {
            return waitingFor != nil ? (live.use.name == "AskUserQuestion" ? "Waiting for your answer" : "Waiting for approval") : "\(live.verb.present) \(live.subject)"
        }

        guard isFinished, workCount == 1 else { return ToolCall.summary(of: calls) }

        return turn.duration.map { "Worked for \($0.formatted(elapsedFormat))" } ?? "Worked"
    }

    private var working: some View {
        ConversationWorking(agent: agent, since: since)
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
                Button("Review Changes") { reviewChanges(changes.paths) }
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
    let details: [String: ToolCallDetails]
    let openCall: ToolCall?
    let isWaiting: Bool

    var body: some View {
        switch part {
        case let .reply(entry):
            ConversationReply(text: entry.text, selectionID: "reply:\(entry.id)")

        case let .work(calls):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(calls) { call in
                    ConversationToolRow(call: call, details: details[call.id] ?? call.details, state: call.id == openCall?.id ? (isWaiting ? .waiting : .running) : .finished)
                }
            }

        case let .cards(calls):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(calls) { call in
                    ConversationTaskRow(call: call, task: tasks.first { $0.id == call.use.toolID || ($0.toolUseID != nil && $0.toolUseID == call.use.toolID) || (call.use.date != nil && $0.started == call.use.date && $0.title == call.cardTitle) })
                }
            }
        }
    }
}

private struct ConversationFold<Content: View>: View {
    let label: String
    let state: ConversationToolState
    @ViewBuilder let content: Content

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = conversationExpandsAll

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                ConversationFoldLabel(label: label, state: state, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                content
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.foreground.opacity(0.14))
                            .frame(width: 1)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}

private struct ConversationFoldLabel: View {
    let label: String
    let state: ConversationToolState
    let isExpanded: Bool

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if state == .running, !reduceMotion {
                ConversationSpinner()
            } else {
                Text(verbatim: state == .waiting ? "!" : "✻")
                    .foregroundStyle(state == .waiting ? theme.needsYou : theme.secondary)
                    .accessibilityHidden(true)
            }
            Text(label)
                .lineLimit(1)
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
        .onHover { isHovered = $0 }
    }
}

private struct ConversationStatusBar: View {
    let agent: Agent
    let since: Date?
    let isWorking: Bool
    let tasks: [RemoteTask]
    let isAtBottom: Bool
    let jump: () -> Void

    @Environment(\.ghosttyTheme) private var theme
    @Environment(Store.self) private var store
    private let pillTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.92))

    var body: some View {
        let kinds = [RemoteTask.agent, RemoteTask.shell, RemoteTask.monitor].filter { kind in tasks.contains { $0.kind == kind } }

        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 10) {
                if isWorking, !isAtBottom {
                    ConversationWorking(agent: agent, since: since)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(in: .capsule)
                        .transition(pillTransition)
                }
                if !tasks.isEmpty {
                    Button { store.showTasksPane(selecting: tasks.first?.id) } label: {
                        HStack(spacing: 8) {
                            ForEach(kinds, id: \.self) { kind in
                                Image(systemName: RemoteTask(id: "", kind: kind, title: "", started: .now).symbol)
                                    .accessibilityHidden(true)
                            }
                            Text(RemoteTask.summary(of: tasks))
                            Image(systemName: "chevron.right")
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
                    .help("Show Background Tasks")
                }
                if !isAtBottom {
                    Button(action: jump) {
                        Image(systemName: "arrow.down")
                            .frame(width: 31, height: 31)
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
    }
}

private extension PendingApproval {
    var isPermission: Bool {
        if case .permission = self { true } else { false }
    }

    var isActionable: Bool {
        switch self {
        case .permission, .question, .plan: true
        case .loading, .unrepresentable: false
        }
    }
}

private struct ConversationBottomBar: View {
    let model: ConversationModel
    let tab: Tab
    let harness: Harness
    let canAttach: Bool
    let since: Date?
    let isWorking: Bool
    let isActive: Bool
    let isAtBottom: Bool
    let approval: PendingApproval?
    let waiting: (waitingFor: String?, since: Double?)?
    let denial: (waitingFor: String?, since: Double?)?
    @Binding var barHeight: CGFloat
    @Binding var composerFocus: Int
    let jump: () -> Void
    let answer: (RemoteKey) -> Void
    let deny: () -> Void

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @State private var branch: ReviewBranchSummary?

    var body: some View {
        bar
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, theme.background ?? Color(nsColor: .textBackgroundColor)], startPoint: .top, endPoint: .bottom)
                    .frame(height: barHeight)
                    .allowsHitTesting(false)
            }
            .task(id: [tab.folder, String(isWorking)]) {
                while !Task.isCancelled {
                    let summary = await ReviewGit.branchSummary(in: tab.folder)
                    guard !Task.isCancelled else { return }

                    branch = summary
                    try? await Task.sleep(for: .seconds(20))
                }
            }
    }

    private var bar: some View {
        let isShell = tab.kind == .shell || harness.supports(.bashMode) && model.draft.text.hasPrefix("!")

        return VStack(spacing: 10) {
            if let approval, approval.isActionable || approval == .loading {
                ConversationApprovalCard(
                    approval: approval,
                    harness: harness,
                    since: waiting?.since.map { Date(timeIntervalSince1970: $0 / 1000) },
                    answer: answer,
                    deny: denial == nil ? nil : deny,
                    declineWithMessage: { composerFocus += 1 },
                    showTerminal: { AppAction.showTerminal.perform(on: store) }
                )
                .transition(.blurReplace)
            }
            if waiting == nil, model.isTurnOpen, harness.readApproval != nil || !harness.supports(.approvals) {
                TimelineView(.periodic(from: .now, by: 5)) { timeline in
                    if timeline.date.timeIntervalSince(model.lastChange) > 20 {
                        HStack {
                            Text("Still working, or waiting for you in the terminal.")
                            Button("Show Terminal") { AppAction.showTerminal.perform(on: store) }
                                .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                    }
                }
            }
            VStack(spacing: 2) {
                ConversationComposer(model: model, folder: tab.folder, harness: harness, canAttach: canAttach, isShell: isShell, isWorking: isWorking, waiting: denial, focusRequest: composerFocus)
                SessionStatusBar(model: model, tab: tab, harness: harness, isShell: isShell, isWorking: isWorking, isWaiting: waiting != nil, summary: branch)
            }
        }
        .frame(maxWidth: theme.messageWidth)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            ConversationStatusBar(agent: tab.agent, since: since, isWorking: isWorking, tasks: model.tasks, isAtBottom: isAtBottom, jump: jump)
                .alignmentGuide(.top) { $0[.bottom] + 10 }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        .animation(.smooth, value: isActive)
        .animation(.smooth, value: approval)
    }
}
