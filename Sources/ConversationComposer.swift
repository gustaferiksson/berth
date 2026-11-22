import AppKit
import BerthCore
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    let model: ConversationModel
    let isWorking: Bool
    let waiting: (waitingFor: String?, since: Double?)?
    let context: RemoteContext?
    let focusRequest: Int

    @Environment(\.ghosttyTheme) private var theme
    @State private var isImporting = false
    @State private var showsContext = false

    var body: some View {
        let draft = model.draft
        let stops = isWorking && draft.isEmpty
        let placeholder = waiting != nil ? "Decline with a message…" : isWorking ? "Queue for after this turn…" : "Message Claude"

        VStack(spacing: 8) {
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(8))
                        model.notice = nil
                    }
            }
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    if !draft.files.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(draft.files, id: \.self) { file in
                                    ConversationAttachmentChip(file: file) { model.draft.files.removeAll { $0 == file } }
                                }
                            }
                            .padding([.horizontal, .top], 12)
                        }
                        .scrollIndicators(.hidden)
                    }
                    ConversationComposerField(
                        text: Binding { model.draft.text } set: { model.draft.text = $0 },
                        placeholder: placeholder,
                        font: theme.font,
                        color: NSColor(theme.foreground),
                        focusRequest: focusRequest,
                        submit: send,
                        attach: { model.draft.files += $0.filter { !model.draft.files.contains($0) } }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    HStack(spacing: 8) {
                        Menu("Attach", systemImage: "plus") {
                            Button("Attach Files…", systemImage: "paperclip") { isImporting = true }
                        }
                        .labelStyle(.iconOnly)
                        .menuIndicator(.hidden)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help("Attach files or images. You can also drop or paste them.")
                        if let context {
                            contextChip(context)
                        }
                        Spacer(minLength: 0)
                        Button(stops ? "Stop" : "Send", systemImage: stops ? "stop.fill" : "arrow.up") {
                            if stops { model.interrupt() } else { send() }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(!stops && (draft.isEmpty || model.isSending))
                        .help(stops ? "Stop Claude" : waiting != nil ? "Deny and Send (↩)" : "Send (↩)")
                    }
                    .padding([.horizontal, .bottom], 8)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.draft.files += ((try? result.get()) ?? []).filter { !model.draft.files.contains($0) }
        }
    }

    private func send() {
        let waiting = waiting
        Task {
            if let waiting { await model.decline(waitingFor: waiting.waitingFor, since: waiting.since) } else { await model.send() }
        }
    }

    private func contextChip(_ context: RemoteContext) -> some View {
        Button { showsContext = true } label: {
            HStack(spacing: 6) {
                if let tokens = context.tokens, let window = context.window {
                    ContextRing(context: SessionContext(model: context.model, tokens: tokens, window: window), window: window)
                }
                Text(modelName(context.model))
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Context")
        .popover(isPresented: $showsContext, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(modelName(context.model))
                    .font(.headline)
                if let tokens = context.tokens, let window = context.window {
                    ProgressView(value: min(Double(tokens) / Double(window), 1))
                    Text("\(tokenCount(tokens)) of \(tokenCount(window)) tokens, \((Double(tokens) / Double(window)).formatted(.percent.precision(.fractionLength(0)))) full")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Context size unknown until Claude replies")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 260, alignment: .leading)
        }
    }

    private func modelName(_ model: String) -> String {
        let parts = model.split(separator: "-").filter { $0 != "claude" && !($0.count == 8 && Int($0) != nil) }
        let name = parts.filter { Int($0) == nil }.map(\.capitalized).joined(separator: " ")
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        return name + (version.isEmpty ? "" : " " + version)
    }
}

private struct ConversationAttachmentChip: View {
    let file: URL
    let remove: () -> Void

    var body: some View {
        let isImage = UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
        let icon = isImage ? NSImage(contentsOf: file) ?? NSWorkspace.shared.icon(forFile: file.path) : NSWorkspace.shared.icon(forFile: file.path)

        HStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(.rect(cornerRadius: 5))
                .accessibilityHidden(true)
            Text(verbatim: file.lastPathComponent)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button("Remove", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
        .help(file.path)
    }
}
