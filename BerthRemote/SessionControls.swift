import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SessionControls: View {
    let session: RemoteSession?
    let sessionID: String
    let pendingCall: ToolCall?
    let context: RemoteContext?
    let openContext: (() -> Void)?

    @Environment(RemoteClient.self) private var client

    var body: some View {
        Group {
            if let session, session.isLocked {
                Label("Running in another terminal, so read-only here.", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    if let session, session.status == "waiting" {
                        ApprovalCard(session: session, pendingCall: session.waitingFor == "permission prompt" ? pendingCall : nil)
                    }
                    Composer(
                        sessionID: sessionID,
                        isWorking: session?.status == "busy",
                        declining: session?.status == "waiting" ? session : nil,
                        context: context,
                        openContext: openContext,
                        draft: Binding { client.draftTexts[sessionID, default: ""] } set: { client.draftTexts[sessionID] = $0 },
                        attachments: Binding { client.draftAttachments[sessionID, default: []] } set: { client.draftAttachments[sessionID] = $0 }
                    )
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
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
                    Text(question["question"] as? String ?? "Claude has a question")
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
                                .buttonStyle(.glass)
                                .buttonBorderShape(.roundedRectangle(radius: 16))
                            }
                        }
                    }
                }
                Button("Dismiss", role: .destructive, action: deny)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
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
                actions(allow: "Allow", deny: "Deny")
            } else {
                Text("Claude is waiting for an answer on your Mac.")
                    .font(.headline)
                Button("Dismiss", role: .destructive, action: deny)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(client.state != .connected)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 24))
        .sensoryFeedback(.selection, trigger: answers)
        .sensoryFeedback(.warning, trigger: denials)
    }

    private func actions(allow: String, detail: String? = nil, deny title: String) -> some View {
        VStack(spacing: 4) {
            Button { press(.digit1) } label: {
                VStack(spacing: 0) {
                    Text(allow)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
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
    let isWorking: Bool
    let declining: RemoteSession?
    let context: RemoteContext?
    let openContext: (() -> Void)?
    @Binding var draft: String
    @Binding var attachments: [Attachment]

    @Environment(RemoteClient.self) private var client
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sends = 0
    @State private var stops = 0
    @AppStorage("quickReplies") private var replies = QuickReply.defaults
    @State private var confirmedCommand: SlashCommand?
    @FocusState private var isFocused: Bool

    var body: some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        let isUploaded = attachments.allSatisfy { client.uploads[$0.id] == .done }
        let stops = isWorking && isEmpty

        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                AttachmentChip(attachment: attachment, state: client.uploads[attachment.id]) {
                                    attachments.removeAll { $0.id == attachment.id }
                                }
                            }
                        }
                        .padding([.horizontal, .top], 12)
                    }
                    .scrollIndicators(.hidden)
                }
                TextField(declining != nil ? "Decline with a message…" : isWorking ? "Queue for after this turn…" : "Message Claude", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                HStack(spacing: 8) {
                    Menu("Attach", systemImage: "plus") {
                        if client.features.contains(RemoteUpload.feature) {
                            Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                            Button("Files", systemImage: "folder") { isImportingFiles = true }
                        } else {
                            Button("Attach", systemImage: "paperclip") { client.notice = "Update Berth on your Mac to send attachments" }
                        }
                        if !replies.isEmpty {
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
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .frame(minWidth: 44, minHeight: 44)
                    if let context, let openContext {
                        Button(action: openContext) {
                            HStack(spacing: 6) {
                                ContextRing(context: context)
                                Text(modelName(of: context))
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Context")
                    }
                    Spacer(minLength: 0)
                    Button(stops ? "Stop" : "Send", systemImage: stops ? "stop.fill" : "arrow.up") {
                        if stops { stop() } else { send() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!stops && (isEmpty || !isUploaded))
                }
                .padding([.horizontal, .bottom], 8)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .disabled(client.state != .connected)
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

    private func modelName(of context: RemoteContext) -> String {
        let parts = context.model.split(separator: "-").filter { $0 != "claude" && !($0.count == 8 && Int($0) != nil) }
        let name = parts.filter { Int($0) == nil }.map(\.capitalized).joined(separator: " ")
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        let fill = context.tokens.flatMap { tokens in context.window.map { Double(tokens) / Double($0) } }
        return [name + (version.isEmpty ? "" : " " + version), fill?.formatted(.percent.precision(.fractionLength(0)))].compactMap(\.self).joined(separator: " · ")
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
        client.notice = "Claude is still waiting, so your message wasn’t sent"
    }

    private func stop() {
        guard client.send(.session(sessionID: sessionID, action: .interrupt)) else { return }

        stops += 1
    }

    private func failures(in uploads: [String: RemoteClient.UploadState]) -> Int {
        uploads.values.count { if case .failed = $0 { true } else { false } }
    }
}
