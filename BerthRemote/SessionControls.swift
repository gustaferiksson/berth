import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension RemoteAgent {
    static let legacyClaude = Self(name: "Claude", asset: "HarnessClaude", canChangeSettings: true, canAttach: true, canRunBash: true)
}

struct SessionControls: View {
    let session: RemoteSession?
    let sessionID: String
    let pendingCall: ToolCall?
    let approval: RemoteApproval?
    let context: RemoteContext?
    let openContext: (() -> Void)?
    let isKeyboardUp: Bool

    @Environment(RemoteClient.self) private var client

    var body: some View {
        if let session, session.isLocked {
            Label("Running in another terminal, so read-only here.", systemImage: "lock")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                if let session, session.status == "waiting" {
                    ApprovalCard(session: session, pendingCall: approvalCall(for: session))
                        .padding(.bottom, 8)
                }
                Composer(
                    sessionID: sessionID,
                    agent: session?.agent ?? .legacyClaude,
                    isWorking: session?.status == "busy",
                    declining: session.flatMap { waiting in
                        guard waiting.status == "waiting", waiting.waitingFor != "needs input" else { return nil }
                        guard waiting.agent?.approvalKeys != nil else { return waiting }

                        return approvalCall(for: waiting).flatMap { $0.use.name == "AskUserQuestion" ? nil : waiting }
                    },
                    context: context,
                    openContext: openContext,
                    isKeyboardUp: isKeyboardUp,
                    draft: Binding { client.draftTexts[sessionID, default: ""] } set: { client.draftTexts[sessionID] = $0 },
                    attachments: Binding { client.draftAttachments[sessionID, default: []] } set: { client.draftAttachments[sessionID] = $0 }
                )
            }
        }
    }

    private func approvalCall(for session: RemoteSession) -> ToolCall? {
        if session.waitingFor == "permission prompt" { return pendingCall }
        guard let approval, approval.waitingSince == session.waitingSince else { return nil }

        return ToolCall(use: approval.call, result: nil)
    }
}

private struct ApprovalCard: View {
    let session: RemoteSession
    let pendingCall: ToolCall?

    @Environment(RemoteClient.self) private var client
    @State private var answers = 0
    @State private var denials = 0
    @State private var isExpanded = false

    var body: some View {
        let agent = session.agent ?? .legacyClaude
        let name = pendingCall?.use.name ?? ""
        let input = pendingCall.flatMap { try? JSONSerialization.jsonObject(with: Data($0.use.text.utf8)) as? [String: Any] }
        let questions = input?["questions"] as? [[String: Any]] ?? []
        let choices = questions.count == 1 && questions[0]["multiSelect"] as? Bool != true ? questions[0]["options"] as? [[String: Any]] ?? [] : []
        let plan = input?["plan"] as? String
        let target = pendingCall.flatMap { $0.use.command ?? $0.use.filePath ?? input?["url"] as? String ?? $0.use.text }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(name == "AskUserQuestion" ? "Question" : pendingCall == nil ? "Needs You" : "Needs Approval")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.orange)
                Spacer()
                if let since = session.waitingSince {
                    ElapsedText(since: Date(timeIntervalSince1970: since / 1000))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Waiting for \(Duration.seconds(max(0, Date.now.timeIntervalSince1970 - since / 1000).rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2)))")
                }
            }
            if name == "AskUserQuestion" {
                ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                    Text(question["question"] as? String ?? "\(agent.name) has a question")
                        .font(.headline)
                }
                if choices.isEmpty || choices.count > 9 {
                    Text("This one needs more than a tap, so answer it on your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    GlassEffectContainer(spacing: 8) {
                        VStack(spacing: 8) {
                            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                                Button {
                                    press(RemoteKey(rawValue: "digit\(index + 1)") ?? .digit1)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(choice["label"] as? String ?? "Option \(index + 1)")
                                            .font(.body.weight(.semibold))
                                        if let detail = choice["description"] as? String {
                                            Text(detail)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.roundedRectangle(radius: 16))
                            }
                        }
                    }
                }
                if (agent.approvalKeys?.deny ?? .escape) == .escape {
                    Button("Dismiss", role: .destructive, action: deny)
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                }
            } else if let plan {
                Text("Ready to start?")
                    .font(.headline)
                Text(plan)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 6)
                if plan.count > 240 || plan.filter(\.isNewline).count > 5 {
                    Button(isExpanded ? "Show Less" : "Show More") { isExpanded.toggle() }
                        .font(.footnote)
                }
                actions(allow: "Approve Plan", detail: "Auto-accept edits", deny: "Keep Planning")
            } else if let pendingCall, let target {
                Text(verbatim: name)
                    .font(.headline)
                if let detail = pendingCall.use.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: target)
                    .font(.footnote.monospaced())
                    .lineLimit(isExpanded ? nil : 4)
                    .truncationMode(pendingCall.use.filePath == nil ? .tail : .middle)
                    .textSelection(.enabled)
                if target.count > 160 || target.filter(\.isNewline).count > 3 {
                    Button(isExpanded ? "Show Less" : "Show More") { isExpanded.toggle() }
                        .font(.footnote)
                }
                actions(allow: "Allow", deny: "Deny", always: agent.approvalKeys?.always)
            } else {
                Text("\(agent.name) is waiting for an answer on your Mac.")
                    .font(.headline)
                if session.waitingFor != "needs input", agent.approvalKeys == nil {
                    Button("Dismiss", role: .destructive, action: deny)
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .disabled(client.state != .connected)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.08)), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(ComposerLayout.cornerRadius)), isUniform: true))
        .sensoryFeedback(.selection, trigger: answers)
        .sensoryFeedback(.warning, trigger: denials)
    }

    private func actions(allow: String, detail: String? = nil, deny title: String, always: RemoteKey? = nil) -> some View {
        VStack(spacing: 4) {
            Button { press(session.agent?.approvalKeys?.approve ?? .digit1) } label: {
                VStack(spacing: 0) {
                    Text(allow)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if let always {
                Button("Always Allow") { press(always) }
                    .buttonStyle(.bordered)
            }
            Button(title, role: .destructive, action: deny)
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func press(_ key: RemoteKey) {
        answers += 1
        client.send(.key(sessionID: session.id, key: key, waitingFor: session.waitingFor, waitingSince: session.waitingSince))
    }

    private func deny() {
        denials += 1
        client.send(.key(sessionID: session.id, key: .escape, waitingFor: session.waitingFor, waitingSince: session.waitingSince))
    }
}

private struct Composer: View {
    let sessionID: String
    let agent: RemoteAgent
    let isWorking: Bool
    let declining: RemoteSession?
    let context: RemoteContext?
    let openContext: (() -> Void)?
    let isKeyboardUp: Bool
    @Binding var draft: String
    @Binding var attachments: [Attachment]

    @Environment(RemoteClient.self) private var client
    @State private var pickedModel: ModelChoice?
    @State private var pickedEffort: EffortLevel?
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sends = 0
    @State private var stops = 0
    @AppStorage("showsQuickReplies") private var showsReplies = true
    @AppStorage("quickReplies") private var replies = QuickReply.defaults
    @State private var confirmedCommand: QuickSlashCommand?
    @State private var selection: TextSelection?
    @State private var selectedSlashCommand: String?
    @State private var dismissedSlashQuery: String?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var plusGlyphSize = 18.0

    private let controlFill = Color.primary.opacity(0.14)

    private var commands: [SlashCommand] {
        client.slashCommands[sessionID] ?? (agent.asset == "HarnessCodex" ? SlashCommand.codexBuiltIns : SlashCommand.claudeBuiltIns)
    }

    private var slashQuery: String? {
        slashToken?.query
    }

    private var slashToken: (query: String, replacing: Range<String.Index>)? {
        guard isFocused, let selection else { return SlashToken.find(in: draft, caret: draft.endIndex) }
        guard case let .selection(range) = selection.indices, range.isEmpty else { return nil }

        return SlashToken.find(in: draft, caret: range.lowerBound)
    }

    var body: some View {
        let query = slashQuery
        let matches: [SlashCommand] = if let query, query != dismissedSlashQuery { SlashCommand.matching(query, in: commands) } else { [] }
        let selected = matches.first { $0.name == selectedSlashCommand } ?? matches.first
        let needsCommands = query != nil && client.state == .connected && client.features.contains(RemoteSlashCommand.feature)

        VStack(spacing: 6) {
            if let selected {
                ComposerSlashMenu(matches: matches, selected: selected.name, pick: complete)
            }
            composer(matches: matches, selected: selected)
        }
        .disabled(client.state != .connected)
        .task(id: needsCommands ? sessionID : nil) {
            guard needsCommands else { return }

            client.loadSlashCommands(for: sessionID)
        }
        .onChange(of: query) {
            dismissedSlashQuery = nil
            selectedSlashCommand = nil
        }
    }

    private func composer(matches: [SlashCommand], selected: SlashCommand?) -> some View {
        let isExpanded = isFocused || !draft.isEmpty || !attachments.isEmpty
        let isShell = agent.canRunBash == true && draft.hasPrefix("!")
        let shape = isKeyboardUp ? AnyShape(.rect(cornerRadius: ComposerLayout.keyboardCornerRadius, style: .continuous)) : AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(ComposerLayout.cornerRadius)), isUniform: true))

        return ComposerLayout(isExpanded: isExpanded, hasAttachmentMenu: agent.canAttach) {
            TextField(declining != nil ? "Decline with a message…" : isWorking ? "Queue for after this turn…" : "Message \(agent.name)", text: $draft, selection: $selection, axis: .vertical)
                .font(isShell ? .body.monospaced() : .body)
                .textFieldStyle(.plain)
                .lineLimit(1...(isExpanded ? 6 : 1))
                .focused($isFocused)
                .onKeyPress(keys: [.upArrow, .downArrow, .tab, .return, .escape], phases: [.down, .repeat]) { press in
                    guard press.modifiers.isEmpty, let selected, let index = matches.firstIndex(of: selected) else { return .ignored }

                    if press.key == .escape {
                        dismissedSlashQuery = slashQuery
                    } else if press.key == .return || press.key == .tab {
                        complete(selected)
                    } else {
                        let step = press.key == .upArrow ? -1 : 1
                        selectedSlashCommand = matches[(index + step + matches.count) % matches.count].name
                    }
                    return .handled
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                if agent.canAttach {
                    attachmentMenu
                }
                if isExpanded, agent.canChangeSettings, let context, let openContext {
                    modelMenu(context, openContext: openContext)
                }
            }
            trailingControls(isExpanded: isExpanded)
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentTile(attachment: attachment, state: client.uploads[attachment.id]) { remove(attachment) }
                        }
                    }
                    .padding(.horizontal, ComposerLayout.expandedInset)
                    .padding(.top, ComposerLayout.expandedInset)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipShape(shape)
        .glassEffect(.regular.tint(colorScheme == .dark ? Color.white.opacity(0.1) : nil), in: shape)
        .overlay { shape.stroke(.primary.opacity(colorScheme == .dark ? 0.18 : 0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(isExpanded ? 0.08 : 0), radius: 10, y: 2)
        .overlay { shape.stroke(.pink.opacity(0.6), lineWidth: 1).opacity(isShell ? 1 : 0) }
        .animation(.smooth(duration: 0.2), value: isShell)
        .animation(.smooth(duration: 0.3), value: isExpanded)
        .onChange(of: draft) {
            attachments.removeAll { $0.number.map { !draft.contains("[Image #\($0)]") } ?? false }
        }
        .onChange(of: context) { old, new in
            if old?.model != new?.model || old?.date != new?.date { pickedModel = nil }
            if old?.effort != new?.effort { pickedEffort = nil }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .confirmationDialog("Clear this conversation?", isPresented: Binding { confirmedCommand != nil } set: { if !$0 { confirmedCommand = nil } }, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                guard let confirmedCommand else { return }

                sendCommand(confirmedCommand)
            }
        } message: {
            Text("/clear starts over with an empty conversation. This can’t be undone from here.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: stops)
        .sensoryFeedback(.error, trigger: client.uploads) { old, new in failures(in: new) > failures(in: old) }
        .photosPicker(isPresented: $isPickingPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await importFiles((try? result.get()) ?? []) }
        }
        .onChange(of: photoItems) {
            let items = photoItems
            photoItems = []
            Task { await importPhotos(items) }
        }
        #if DEBUG
        .task { await attachForSnapshot() }
        #if DEBUG
        .task {
            guard UserDefaults.standard.bool(forKey: "snapshotDemoFocus") else { return }

            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            isFocused = true
        }
        #endif
        .task {
            guard focusesAndExpands else { return }

            try? await Task.sleep(for: .seconds(4))
            isFocused = true
        }
        #endif
    }

    private var attachmentMenu: some View {
        Menu {
            if client.features.contains(RemoteUpload.feature) {
                Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                Button("Files", systemImage: "folder") { isImportingFiles = true }
            } else {
                Button("Attach", systemImage: "paperclip") { client.notice = "Update Berth on your Mac to send attachments" }
            }
            if showsReplies, !replies.isEmpty {
                Section("Replies") {
                    ForEach(replies) { reply in
                        Button(reply.text) { insert(reply.text) }
                    }
                }
            }
            Section("Commands") {
                ForEach(QuickSlashCommand.all) { command in
                    Button(command.name, systemImage: command.symbol, role: command.isDestructive ? .destructive : nil) { run(command) }
                }
            }
        } label: {
            Label("Attach", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.system(
                    size: plusGlyphSize,
                    weight: .medium
                ))
                .frame(width: ComposerLayout.controlSize, height: ComposerLayout.controlSize)
                .background(controlFill, in: .circle)
                .frame(width: ComposerLayout.hitSize, height: ComposerLayout.hitSize)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    private func trailingControls(isExpanded _: Bool) -> some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        let showsStop = isWorking && isEmpty
        let canSend = !isEmpty && attachments.allSatisfy { client.uploads[$0.id] == .done }
        let isAvailable = client.state == .connected && (showsStop || canSend)

        return HStack(spacing: 3) {
            if let context, let openContext {
                if !agent.canChangeSettings {
                    Button(action: openContext) {
                        Image(systemName: "chart.pie")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: ComposerLayout.controlSize, height: ComposerLayout.controlSize)
                            .background(controlFill, in: .circle)
                            .frame(width: ComposerLayout.hitSize, height: ComposerLayout.hitSize)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(context.model)
                    .accessibilityHint("Shows context usage")
                }
            }
            Button {
                if showsStop {
                    stop()
                    return
                }

                send()
            } label: {
                Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                    .foregroundStyle(isAvailable ? Color.white : Color.secondary)
                    .frame(width: ComposerLayout.controlSize, height: ComposerLayout.controlSize)
                    .background(isAvailable ? Color.accentColor : controlFill, in: .circle)
                    .frame(width: ComposerLayout.hitSize, height: ComposerLayout.hitSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .accessibilityLabel(showsStop ? "Stop" : "Send")
            .animation(.snappy(duration: 0.2), value: showsStop)
            .animation(.snappy(duration: 0.2), value: isAvailable)
        }
        .focusedSceneValue(\.composerActions, ComposerActions(
            canSend: client.state == .connected && canSend,
            canStop: client.state == .connected && showsStop,
            send: send,
            stop: stop
        ))
    }

    private func modelMenu(_ context: RemoteContext, openContext: @escaping () -> Void) -> some View {
        let canChange = client.features.contains(RemoteSessionSettingsFeature.name) && !isWorking && declining == nil
        let currentModel = pickedModel ?? ModelChoice(modelID: context.model)
        let currentEffort = pickedEffort ?? context.effort.flatMap(EffortLevel.init)
        let modelChoice = Binding<ModelChoice?> { currentModel } set: { choice in
            guard let choice else { return }

            change(.model(choice), from: .model(currentModel ?? .default))
            pickedModel = choice
        }
        let effortChoice = Binding<EffortLevel?> { currentEffort } set: { level in
            guard let level, let currentEffort else { return }

            change(.effort(level), from: .effort(currentEffort))
            pickedEffort = level
        }
        let modelTitle = pickedModel.flatMap { $0 == .default ? nil : $0.title } ?? modelName(of: context)

        return Menu {
            if client.features.contains(RemoteSessionSettingsFeature.name) {
                Section("Model") {
                    Picker("Model", selection: modelChoice) {
                        ForEach(ModelChoice.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .disabled(!canChange)
                Section("Effort") {
                    Picker("Effort", selection: effortChoice) {
                        ForEach(EffortLevel.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .disabled(!canChange || currentEffort == nil)
                Text(canChange ? "Changes apply to this session only" : "Available while \(agent.name) is idle")
            }
            Button("Context", systemImage: "chart.pie", action: openContext)
        } label: {
            Text("\(Text(modelTitle))\(Text(currentEffort.map { " \($0.title)" } ?? "").foregroundStyle(.secondary))")
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: ComposerLayout.controlSize)
                .background(controlFill, in: .capsule)
                .frame(minWidth: ComposerLayout.hitSize)
                .frame(height: ComposerLayout.hitSize)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Model, effort and context")
    }

    private func change(_ setting: RemoteSessionSetting, from current: RemoteSessionSetting) {
        guard client.send(.setting(sessionID: sessionID, setting: setting, from: current)) else { return }

        sends += 1
    }

    private func modelName(of context: RemoteContext) -> String {
        let parts = context.model.split(separator: "-").filter { $0 != "claude" && !($0.count == 8 && Int($0) != nil) }
        let name = parts.filter { Int($0) == nil }.map(\.capitalized).joined(separator: " ")
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        return name + (version.isEmpty ? "" : " " + version)
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                client.notice = "That photo couldn’t be loaded"
                continue
            }

            await attach(data, name: "Photo", isImage: true)
        }
    }

    private func importFiles(_ urls: [URL]) async {
        for url in urls {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= RemoteUpload.maxBytes, let data = try? Data(contentsOf: url) else {
                client.notice = "\(url.lastPathComponent) is over \(RemoteUpload.maxBytes >> 20) MB or couldn’t be read"
                continue
            }

            await attach(data, name: url.lastPathComponent, isImage: UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true)
        }
    }

    private func attach(_ data: Data, name: String, isImage: Bool) async {
        guard let prepared = await Task.detached(operation: { Attachment.prepared(data, name: name, isImage: isImage) }).value else {
            client.notice = isImage ? "\(name) couldn’t be read as an image or is over \(RemoteUpload.maxBytes >> 20) MB" : "\(name) is over \(RemoteUpload.maxBytes >> 20) MB"
            return
        }

        var attachment = prepared.attachment
        if isImage {
            let sent = client.entries[sessionID, default: []].lazy.compactMap { $0.imageNumbers?.max() }.max() ?? 0
            let pending = client.pendingAttachments[sessionID, default: [:]].values.joined().lazy.compactMap(\.number).max() ?? 0
            let number = max(attachments.lazy.compactMap(\.number).max() ?? 0, sent, pending) + 1
            attachment.number = number
            await insertAtCaret("[Image #\(number)]")
        }
        attachments.append(attachment)
        await client.upload(prepared.data, id: prepared.attachment.id, name: prepared.attachment.name)
    }

    #if DEBUG
    private func attachForSnapshot() async {
        guard attachments.isEmpty, let paths = UserDefaults.standard.string(forKey: "snapshotAttachments") else { return }

        try? await Task.sleep(for: .seconds(1))
        for path in paths.split(separator: "|").map(String.init) {
            guard let data = FileManager.default.contents(atPath: path) else { continue }

            await attach(data, name: URL(filePath: path).lastPathComponent, isImage: UTType(filenameExtension: URL(filePath: path).pathExtension)?.conforms(to: .image) == true)
        }
        guard let text = UserDefaults.standard.string(forKey: "snapshotDraft") else { return }

        draft += text
        guard UserDefaults.standard.bool(forKey: "snapshotSend") else { return }

        while !attachments.allSatisfy({ client.uploads[$0.id] == .done }) { try? await Task.sleep(for: .milliseconds(200)) }
        send()
    }
    #endif

    private func insertAtCaret(_ token: String) async {
        var caret = draft.endIndex
        if case let .selection(range)? = selection?.indices, draft.indices.contains(range.upperBound) || range.upperBound == draft.endIndex {
            caret = range.upperBound
        }
        let before = draft[..<caret]
        let leading = before.isEmpty || before.last?.isWhitespace == true ? "" : " "
        let after = draft[caret...]
        let trailing = after.first?.isWhitespace == true ? "" : " "
        let inserted = leading + token + trailing
        let offset = draft.distance(from: draft.startIndex, to: caret) + inserted.count
        draft.insert(contentsOf: inserted, at: caret)
        await Task.yield()
        selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset))
    }

    private func remove(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
        guard let number = attachment.number else { return }

        draft = draft.replacing("[Image #\(number)]", with: "")
    }

    private func insert(_ text: String) {
        draft = draft.isEmpty || draft.last?.isWhitespace == true ? draft + text : draft + " " + text
        isFocused = true
    }

    private func complete(_ command: SlashCommand) {
        guard let token = slashToken else { return }

        let caretOffset = draft.distance(from: draft.startIndex, to: token.replacing.lowerBound) + command.name.count + 1
        draft.replaceSubrange(token.replacing, with: command.name + " ")
        let completed = draft
        selection = nil
        isFocused = true
        Task {
            await Task.yield()
            guard draft == completed else { return }

            selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: caretOffset))
        }
    }

    private func run(_ command: QuickSlashCommand) {
        if command.isDestructive {
            confirmedCommand = command
            return
        }

        sendCommand(command)
    }

    private func sendCommand(_ command: QuickSlashCommand) {
        guard client.send(.prompt(sessionID: sessionID, text: command.name, attachments: nil)) else { return }

        sends += 1
    }

    private func send() {
        guard allowsSendingCommand() else { return }

        if let declining {
            Task { await decline(declining) }
            return
        }

        guard client.sendDraft(to: sessionID) else { return }

        sends += 1
    }

    private func allowsSendingCommand() -> Bool {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.hasPrefix("/"), let command = commands.first(where: { $0.requiresArguments && $0.name.lowercased() == name }) else { return true }

        client.notice = "\(command.name) needs an argument"
        return false
    }

    private func decline(_ waiting: RemoteSession) async {
        guard client.send(.key(sessionID: sessionID, key: .escape, waitingFor: waiting.waitingFor, waitingSince: waiting.waitingSince)) else { return }

        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            guard client.groups.lazy.flatMap(\.sessions).first(where: { $0.id == sessionID })?.status == "waiting" else {
                if allowsSendingCommand(), client.sendDraft(to: sessionID) { sends += 1 }
                return
            }
        }
        client.notice = "\(agent.name) is still waiting, so your message wasn’t sent"
    }

    private func stop() {
        guard client.send(.session(sessionID: sessionID, action: .interrupt)) else { return }

        stops += 1
    }

    private func failures(in uploads: [String: RemoteClient.UploadState]) -> Int {
        uploads.values.count { if case .failed = $0 { true } else { false } }
    }
}

struct ComposerLayout: Layout {
    let isExpanded: Bool
    let hasAttachmentMenu: Bool

    static let controlSize: CGFloat = 34
    static let hitSize: CGFloat = 44
    static let compactInset: CGFloat = 8
    static let cornerRadius = controlSize / 2 + compactInset
    static let expandedInset: CGFloat = 14
    static let keyboardCornerRadius: CGFloat = 30
    static let tileRadius = cornerRadius - expandedInset

    private static let textGap: CGFloat = 8
    private static let hitPadding = (hitSize - controlSize) / 2

    private var controlInset: CGFloat { isExpanded ? Self.expandedInset : Self.compactInset }
    private var controlsHeight: CGFloat { Self.controlSize + 2 * controlInset }
    private var hitInset: CGFloat { controlInset - Self.hitPadding }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 361
        return CGSize(width: width, height: measure(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let metrics = measure(width: bounds.width, subviews: subviews)
        let controlsCenter = bounds.maxY - controlsHeight / 2
        let fieldProposal = ProposedViewSize(width: metrics.field.width, height: metrics.field.height)
        let font = UIFont.preferredFont(forTextStyle: .body)
        let fieldTop = isExpanded ? bounds.minY + metrics.field.minY : bounds.midY + font.capHeight / 2 - font.ascender

        subviews[0].place(at: CGPoint(x: bounds.minX + metrics.field.minX, y: fieldTop), anchor: .topLeading, proposal: fieldProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX + hitInset, y: controlsCenter), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX - hitInset, y: controlsCenter), anchor: .trailing, proposal: ProposedViewSize(metrics.trailing))
        if subviews.count > 3 {
            subviews[3].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: metrics.tilesHeight))
        }
    }

    private func measure(width: CGFloat, subviews: Subviews) -> (height: CGFloat, field: CGRect, trailing: CGSize, tilesHeight: CGFloat) {
        let leadingWidth = subviews[1].sizeThatFits(.unspecified).width
        let trailingWidth = max(Self.hitSize, width - leadingWidth - 2 * hitInset)
        let trailing = subviews[2].sizeThatFits(ProposedViewSize(width: trailingWidth, height: controlsHeight))
        let fieldLeading = isExpanded ? Self.expandedInset : hasAttachmentMenu ? controlsHeight : 14
        let fieldTrailing = isExpanded ? Self.expandedInset : trailing.width + 2 * hitInset
        let fieldWidth = max(0, width - fieldLeading - fieldTrailing)
        let fieldHeight = max(22, subviews[0].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil)).height)

        guard isExpanded else {
            let height = max(controlsHeight, fieldHeight)
            let field = CGRect(x: fieldLeading, y: (height - fieldHeight) / 2, width: fieldWidth, height: fieldHeight)
            return (height, field, trailing, 0)
        }

        let tilesHeight = subviews.count > 3 ? subviews[3].sizeThatFits(ProposedViewSize(width: width, height: nil)).height : 0
        let field = CGRect(x: fieldLeading, y: tilesHeight > 0 ? tilesHeight + Self.textGap : Self.expandedInset, width: fieldWidth, height: fieldHeight)
        return (field.maxY + Self.textGap + Self.controlSize + controlInset, field, trailing, tilesHeight)
    }
}
