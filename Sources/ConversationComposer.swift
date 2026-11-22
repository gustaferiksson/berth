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

    private static let inset = 6.0
    private static let controlHeight = 28.0
    private static let tileSize = 56.0

    @Environment(\.ghosttyTheme) private var theme
    @State private var isImporting = false
    @State private var showsContext = false

    var body: some View {
        let draft = model.draft
        let stops = isWorking && draft.isEmpty
        let placeholder = waiting != nil ? "Decline with a message…" : isWorking ? "Queue for after this turn…" : "Message Claude"

        GlassEffectContainer(spacing: 8) {
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
                VStack(alignment: .leading, spacing: 0) {
                    if !draft.files.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileSize, maximum: Self.tileSize), spacing: Self.inset)], alignment: .leading, spacing: Self.inset) {
                            ForEach(draft.files, id: \.self) { file in
                                ConversationAttachmentTile(file: file, number: draft.numbers[file], size: Self.tileSize, radius: Self.controlHeight / 2) { model.remove(file) }
                            }
                        }
                        .padding(.top, Self.inset)
                    }
                    ConversationComposerField(
                        text: Binding { model.draft.text } set: { model.setText($0) },
                        placeholder: placeholder,
                        font: theme.font,
                        color: NSColor(theme.foreground),
                        focusRequest: focusRequest,
                        submit: send,
                        attach: { model.attach($0) }
                    )
                    .padding(.vertical, Self.inset)
                    HStack(spacing: 8) {
                        Menu {
                            Button("Attach Files…", systemImage: "paperclip") { isImporting = true }
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: Self.controlHeight, height: Self.controlHeight)
                                .background(.quaternary, in: .circle)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Attach")
                        .help("Attach files or images. You can also drop or paste them.")
                        if let context {
                            modelMenu(context)
                        }
                        Spacer(minLength: 0)
                        if stops || !(draft.isEmpty || model.isSending) {
                            Button {
                                if stops { model.interrupt() } else { send() }
                            } label: {
                                Image(systemName: stops ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: Self.controlHeight, height: Self.controlHeight)
                                    .background(Color.accentColor, in: .circle)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(stops ? "Stop" : "Send")
                            .help(stops ? "Stop Claude" : waiting != nil ? "Deny and Send (↩)" : "Send (↩)")
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .frame(width: Self.controlHeight, height: Self.controlHeight)
                                .background(.quaternary, in: .circle)
                                .accessibilityLabel("Send, unavailable")
                        }
                    }
                }
                .padding([.horizontal, .bottom], Self.inset)
                .glassEffect(.regular, in: .rect(cornerRadius: Self.controlHeight / 2 + Self.inset))
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.append((try? result.get()) ?? [])
        }
    }

    private func send() {
        let waiting = waiting
        Task {
            if let waiting { await model.decline(waitingFor: waiting.waitingFor, since: waiting.since) } else { await model.send() }
        }
    }

    private func modelMenu(_ context: RemoteContext) -> some View {
        let canChange = !isWorking && waiting == nil && !model.isSending
        let model = model
        let modelChoice = Binding<ModelChoice?> {
            model.pickedModel ?? ModelChoice(modelID: context.model)
        } set: { choice in
            guard let choice else { return }

            Task { await model.choose(.model(choice)) }
        }
        let effortChoice = Binding<EffortLevel?> {
            model.pickedEffort ?? context.effort.flatMap(EffortLevel.init)
        } set: { level in
            guard let level else { return }

            Task { await model.choose(.effort(level)) }
        }
        let modelTitle = model.pickedModel.flatMap { $0 == .default ? nil : $0.title } ?? modelName(context.model)

        return Menu {
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
            .disabled(!canChange || context.effort == nil && model.pickedEffort == nil)
            Divider()
            Button("Context", systemImage: "chart.pie") { showsContext = true }
            Text(canChange ? "Changes apply to this session only" : "Available while Claude is idle")
        } label: {
            Text("\(Text(modelTitle)) \(Text(effortChoice.wrappedValue?.title ?? "").foregroundStyle(.secondary))")
                .lineLimit(1)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(height: Self.controlHeight)
                .background(.quaternary, in: .capsule)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Model and effort")
        .help("Model, effort and context")
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

private struct ConversationAttachmentTile: View {
    let file: URL
    let number: Int?
    let size: Double
    let radius: Double
    let remove: () -> Void

    var body: some View {
        let isImage = number != nil || UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true
        let image = isImage ? NSImage(contentsOf: file) : nil

        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .scaledToFit()
                    .padding(8)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
        .overlay(alignment: .bottomLeading) {
            if let number {
                Text(number, format: .number)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .capsule)
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(.black.opacity(0.6), in: .circle)
                    .padding(4)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(file.lastPathComponent)")
        }
        .help(file.lastPathComponent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(number.map { "Image \($0), \(file.lastPathComponent)" } ?? file.lastPathComponent)
    }
}
