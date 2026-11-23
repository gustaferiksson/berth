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
        .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 24))
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
    @State private var confirmedCommand: SlashCommand?
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .body) private var plusGlyphSize = 18.0

    private let controlFill = Color.primary.opacity(0.06)

    var body: some View {
        let isExpanded = isFocused || !draft.isEmpty || !attachments.isEmpty
        let isShell = agent.canRunBash == true && draft.hasPrefix("!")
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(ComposerLayout.cornerRadius)))
        let glass: Glass = isShell ? .regular.tint(.pink.opacity(0.12)) : .regular

        ComposerLayout(isExpanded: isExpanded, hasAttachmentMenu: agent.canAttach) {
            TextField(declining != nil ? "Decline with a message…" : isWorking ? "Queue for after this turn…" : "Message \(agent.name)", text: $draft, axis: .vertical)
                .font(isShell ? .body.monospaced() : .body)
                .textFieldStyle(.plain)
                .lineLimit(1...(isExpanded ? 6 : 1))
                .focused($isFocused)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                if agent.canAttach {
                    attachmentMenu
                }
            }
            trailingControls(isExpanded: isExpanded, isShell: isShell)
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentTile(attachment: attachment, state: client.uploads[attachment.id]) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.horizontal, ComposerLayout.controlInset)
                    .padding(.top, ComposerLayout.controlInset)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .clipShape(shape)
        .glassEffect(glass, in: shape)
        .overlay { shape.stroke(.pink, lineWidth: 1.5).opacity(isShell ? 1 : 0) }
        .animation(.smooth(duration: 0.2), value: isShell)
        .animation(.smooth(duration: 0.3), value: isExpanded)
        .disabled(client.state != .connected)
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
                ForEach(SlashCommand.all) { command in
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

    private func trailingControls(isExpanded: Bool, isShell: Bool) -> some View {
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
                } else if isExpanded {
                    modelMenu(context, openContext: openContext)
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
                    .background(isAvailable ? (isShell ? Color.pink : Color.accentColor) : controlFill, in: .circle)
                    .frame(width: ComposerLayout.hitSize, height: ComposerLayout.hitSize)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .accessibilityLabel(showsStop ? "Stop" : "Send")
            .animation(.snappy(duration: 0.2), value: showsStop)
            .animation(.snappy(duration: 0.2), value: isAvailable)
        }
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
            Text([modelTitle, currentEffort?.title].compactMap(\.self).joined(separator: " "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

        attachments.append(prepared.attachment)
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

        draft = text
        guard UserDefaults.standard.bool(forKey: "snapshotSend") else { return }

        while !attachments.allSatisfy({ client.uploads[$0.id] == .done }) { try? await Task.sleep(for: .milliseconds(200)) }
        send()
    }
    #endif

    private func insert(_ text: String) {
        draft = draft.isEmpty || draft.last?.isWhitespace == true ? draft + text : draft + " " + text
        isFocused = true
    }

    private func run(_ command: SlashCommand) {
        if command.isDestructive {
            confirmedCommand = command
            return
        }

        sendCommand(command)
    }

    private func sendCommand(_ command: SlashCommand) {
        guard client.send(.prompt(sessionID: sessionID, text: command.name, attachments: nil)) else { return }

        sends += 1
    }

    private func send() {
        if let declining {
            Task { await decline(declining) }
            return
        }

        guard client.sendDraft(to: sessionID) else { return }

        sends += 1
    }

    private func decline(_ waiting: RemoteSession) async {
        guard client.send(.key(sessionID: sessionID, key: .escape, waitingFor: waiting.waitingFor, waitingSince: waiting.waitingSince)) else { return }

        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            guard client.groups.lazy.flatMap(\.sessions).first(where: { $0.id == sessionID })?.status == "waiting" else {
                if client.sendDraft(to: sessionID) { sends += 1 }
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
    static let controlInset: CGFloat = 8
    static let controlsHeight = controlSize + 2 * controlInset
    static let cornerRadius = controlsHeight / 2
    static let tileRadius = cornerRadius - controlInset

    private static let textInset: CGFloat = 14
    private static let hitPadding = (hitSize - controlSize) / 2
    private static let hitInset = controlInset - hitPadding

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 361
        return CGSize(width: width, height: measure(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let metrics = measure(width: bounds.width, subviews: subviews)
        let controlsCenter = bounds.maxY - Self.controlsHeight / 2
        let fieldProposal = ProposedViewSize(width: metrics.field.width, height: metrics.field.height)
        let font = UIFont.preferredFont(forTextStyle: .body)
        let fieldTop = isExpanded ? bounds.minY + metrics.field.minY : bounds.midY + font.capHeight / 2 - font.ascender

        subviews[0].place(at: CGPoint(x: bounds.minX + metrics.field.minX, y: fieldTop), anchor: .topLeading, proposal: fieldProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX + Self.hitInset, y: controlsCenter), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX - Self.hitInset, y: controlsCenter), anchor: .trailing, proposal: ProposedViewSize(metrics.trailing))
        if subviews.count > 3 {
            subviews[3].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: metrics.tilesHeight))
        }
    }

    private func measure(width: CGFloat, subviews: Subviews) -> (height: CGFloat, field: CGRect, trailing: CGSize, tilesHeight: CGFloat) {
        let leadingWidth = hasAttachmentMenu ? Self.hitSize : 0
        let trailingWidth = max(Self.hitSize, width - leadingWidth - 2 * Self.hitInset)
        let trailing = subviews[2].sizeThatFits(ProposedViewSize(width: trailingWidth, height: Self.controlsHeight))
        let fieldLeading = isExpanded ? 20 : hasAttachmentMenu ? Self.controlSize + 2 * Self.controlInset : 14
        let fieldTrailing = isExpanded ? 20 : trailing.width + 2 * Self.hitInset
        let fieldWidth = max(0, width - fieldLeading - fieldTrailing)
        let fieldHeight = max(22, subviews[0].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil)).height)

        guard isExpanded else {
            let height = max(Self.controlsHeight, fieldHeight)
            let field = CGRect(x: fieldLeading, y: (height - fieldHeight) / 2, width: fieldWidth, height: fieldHeight)
            return (height, field, trailing, 0)
        }

        let tilesHeight = subviews.count > 3 ? subviews[3].sizeThatFits(ProposedViewSize(width: width, height: nil)).height : 0
        let field = CGRect(x: fieldLeading, y: tilesHeight > 0 ? tilesHeight + Self.controlInset : Self.textInset, width: fieldWidth, height: fieldHeight)
        return (field.maxY + Self.textInset - Self.controlInset + Self.controlsHeight, field, trailing, tilesHeight)
    }
}
