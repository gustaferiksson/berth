import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SessionControls: View {
    let session: RemoteSession?
    let sessionID: String
    let turnStart: Date?
    let pendingCall: ToolCall?
    let isAtBottom: Bool
    @Binding var draft: String
    @Binding var attachments: [Attachment]
    let scrollToEnd: () -> Void

    var body: some View {
        let isWorking = session?.status == "busy"

        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                if isWorking || !isAtBottom {
                    ZStack(alignment: .trailing) {
                        if isWorking {
                            WorkingCapsule(since: turnStart)
                                .frame(maxWidth: .infinity)
                        }
                        if !isAtBottom {
                            Button("Scroll to End", systemImage: "arrow.down", action: scrollToEnd)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .controlSize(.large)
                        }
                    }
                }
                if let session, session.isLocked {
                    Label("Running in another terminal, so read-only here.", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if let session, session.status == "waiting" {
                    ApprovalCard(session: session, pendingCall: session.waitingFor == "permission prompt" ? pendingCall : nil)
                } else {
                    Composer(sessionID: sessionID, isWorking: isWorking, draft: $draft, attachments: $attachments)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

private struct WorkingCapsule: View {
    let since: Date?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { context in
            Label {
                if let since {
                    Text("Working \(Duration.seconds(max(0, context.date.timeIntervalSince(since)).rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
                        .monospacedDigit()
                } else {
                    Text("Working")
                }
            } icon: {
                if reduceMotion {
                    Image(systemName: "hourglass")
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: .capsule)
    }
}

private struct ApprovalCard: View {
    let session: RemoteSession
    let pendingCall: ToolCall?

    @Environment(RemoteClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(session.waitingFor.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Needs you", systemImage: "exclamationmark.bubble.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            if let pendingCall {
                Text(pendingCall.use.detail ?? pendingCall.use.name ?? "Tool")
                    .font(.headline)
                if let target = pendingCall.use.command ?? pendingCall.use.filePath {
                    Text(verbatim: target)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            } else {
                Text("Claude is waiting for an answer in Berth.")
                    .font(.headline)
            }
            HStack(spacing: 8) {
                ForEach([("1", RemoteKey.digit1), ("2", .digit2), ("3", .digit3), ("Esc", .escape)], id: \.0) { title, key in
                    Button {
                        client.send(.key(sessionID: session.id, key: key, waitingFor: session.waitingFor, waitingSince: session.waitingSince))
                    } label: {
                        Text(title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .disabled(client.state != .connected)
            Text("Picks an option of Claude’s question by number. Usually 1 is yes, 2 is yes and don’t ask again, 3 is no.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 24))
    }
}

private struct Composer: View {
    let sessionID: String
    let isWorking: Bool
    @Binding var draft: String
    @Binding var attachments: [Attachment]

    @Environment(RemoteClient.self) private var client
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
        let isUploaded = attachments.allSatisfy { client.uploads[$0.id] == .done }

        HStack(alignment: .bottom, spacing: 8) {
            if client.features.contains(RemoteUpload.feature) {
                Menu("Attach", systemImage: "plus") {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { isPickingPhotos = true }
                    Button("Files", systemImage: "folder") { isImportingFiles = true }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
            }
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
                        .padding([.horizontal, .top], 8)
                    }
                    .scrollIndicators(.hidden)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(isWorking ? "Queue for after this turn…" : "Message Claude", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.leading, 16)
                        .padding(.vertical, 12)
                    if isWorking, isEmpty {
                        Button("Stop", systemImage: "stop.fill", action: stop)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .padding(6)
                    } else {
                        Button("Send", systemImage: "arrow.up", action: send)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .padding(6)
                            .disabled(isEmpty || !isUploaded)
                    }
                }
            }
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        }
        .disabled(client.state != .connected)
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
        #endif
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
            client.notice = "\(name) is over \(RemoteUpload.maxBytes >> 20) MB or isn’t a readable image"
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

    private func send() {
        client.send(.prompt(sessionID: sessionID, text: draft, attachments: attachments.isEmpty ? nil : attachments.map(\.id)))
        draft = ""
        attachments = []
    }

    private func stop() {
        client.send(.session(sessionID: sessionID, action: .interrupt))
    }
}
