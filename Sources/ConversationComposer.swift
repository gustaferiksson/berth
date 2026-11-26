import AppKit
import BerthCore
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    let model: ConversationModel
    let folder: String
    let harness: Harness
    let canAttach: Bool
    let isShell: Bool
    let isWorking: Bool
    let waiting: (waitingFor: String?, since: Double?)?
    let focusRequest: Int

    private static let tileSize = 56.0

    @Environment(\.ghosttyTheme) private var theme
    @Environment(Store.self) private var store
    @State private var isImporting = false
    @State private var width: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    @State private var settledHeight: CGFloat = 0
    @State private var slashPicker = ConversationSlashPicker()
    @State private var shellCompleter = ConversationShellCompleter()
    @AppStorage(ConversationShellCompleter.enabledKey) private var completesShell = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let draft = model.draft
        let hidesBang = isShell && draft.text.hasPrefix("!")
        let shownText = hidesBang ? String(draft.text.dropFirst()) : draft.text
        let stops = isWorking && draft.isEmpty
        let canSend = stops || !(draft.isEmpty || model.isSending)
        let font = isShell ? theme.codeFont : theme.composerFont
        let animation = reduceMotion ? nil : Animation.smooth(duration: 0.25)
        let inset = ConversationComposerLayout.inset
        let controlSize = ConversationComposerLayout.controlSize
        let fieldWidth = ConversationComposerLayout.fieldBounds(in: width, canAttach: canAttach).width
        let fieldHeight = ConversationComposerField.height(of: shownText, font: font, width: fieldWidth)
        let animatesHeight = abs(fieldHeight - settledHeight) > controlSize * 1.5
        let shape = RoundedRectangle(cornerRadius: controlSize / 2 + inset)
        let placeholder = hidesBang ? "Run a shell command" : model.blocksSending ? "Wait for \(harness.name) to finish, or stop it" : waiting != nil ? "Decline with a message…" : isWorking ? "Queue for after this turn…" : "Message \(harness.name)"
        let slashScope = isShell || slashPicker.query == nil ? nil : ConversationSlashPicker.Scope(folder: folder, agent: harness.agent)

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
                            guard !Task.isCancelled else { return }

                            model.notice = nil
                        }
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !draft.files.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileSize, maximum: Self.tileSize), spacing: inset)], alignment: .leading, spacing: inset) {
                            ForEach(draft.files, id: \.self) { file in
                                ConversationAttachmentTile(file: file, number: draft.numbers[file], size: Self.tileSize, radius: controlSize / 2) { model.remove(file) }
                            }
                        }
                        .padding([.horizontal, .top], inset)
                    }
                    ConversationComposerLayout(fieldHeight: fieldHeight, canAttach: canAttach) {
                        if canAttach {
                            Menu {
                                Button("Attach Files…", systemImage: "paperclip") { isImporting = true }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: controlSize, height: controlSize)
                                    .background(.quaternary, in: .circle)
                            }
                            .menuIndicator(.hidden)
                            .buttonStyle(.plain)
                            .accessibilityLabel("Attach")
                            .help("Attach files or images. You can also drop or paste them.")
                        } else {
                            Color.clear.frame(width: 0, height: 0)
                                .accessibilityHidden(true)
                        }
                        ConversationComposerField(
                            text: Binding { shownText } set: { model.setText(hidesBang ? "!" + $0 : $0) },
                            placeholder: placeholder,
                            font: font,
                            color: NSColor(theme.foreground),
                            hidesBang: hidesBang,
                            focusRequest: focusRequest,
                            layoutWidth: fieldWidth,
                            slashPicker: isShell ? nil : slashPicker,
                            shellCompleter: isShell && completesShell ? shellCompleter : nil,
                            submit: send,
                            attach: { canAttach ? model.attach($0) : "" },
                            recall: recallQueued,
                            leaveShell: { model.setText(shownText) }
                        )
                        Button {
                            guard stops else { return send() }

                            model.interrupt()
                        } label: {
                            Image(systemName: stops ? "stop.fill" : "arrow.up")
                                .contentTransition(.symbolEffect(.replace))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                                .frame(width: controlSize, height: controlSize)
                                .background(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .circle)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(canSend)
                        .accessibilityLabel(canSend ? (stops ? "Stop" : "Send") : "Send, unavailable")
                        .help(stops ? "Stop \(harness.name)" : waiting != nil ? "Deny and Send (↩)" : "Send (↩)")
                    }
                }
                .overlay { shape.strokeBorder(theme.shellAttached.opacity(0.6), lineWidth: 1).opacity(isShell ? 1 : 0).allowsHitTesting(false) }
                .glassEffect(.regular, in: shape)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .animation(draft.isEmpty ? nil : animation, value: animatesHeight ? fieldHeight : 0)
                .onChange(of: fieldHeight) { settledHeight = fieldHeight }
                .animation(.smooth(duration: 0.2), value: isShell)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        .overlay(alignment: .bottomLeading) {
            pickerMenu(slashScope: slashScope)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: -composerHeight - 6)
        }
        .task(id: slashScope) {
            guard let slashScope else { return }

            slashPicker.commands = store.conversationSlashCommands[slashScope] ?? SlashCommand.builtIns(for: harness)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let folder = URL(filePath: slashScope.folder, directoryHint: .isDirectory)
            let commands = await Task.detached { [harness] in SlashCommand.load(home: home, folder: folder, harness: harness) }.value
            guard !Task.isCancelled else { return }

            store.conversationSlashCommands[slashScope] = commands
            slashPicker.commands = commands
        }
        .onChange(of: isShell) {
            if isShell { slashPicker.update(query: nil) } else { shellCompleter.reset() }
        }
        .onChange(of: completesShell) {
            if !completesShell { shellCompleter.reset() }
        }
        .onChange(of: folder, initial: true) {
            shellCompleter.folder = folder
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.append((try? result.get()) ?? [])
        }
    }

    @ViewBuilder
    private func pickerMenu(slashScope: ConversationSlashPicker.Scope?) -> some View {
        let matches = slashScope == nil ? [] : slashPicker.matches
        if !matches.isEmpty {
            ConversationPickerMenu(
                items: matches,
                id: \.name,
                selected: matches.first { $0.name == slashPicker.selectedName }?.name,
                label: "Slash commands",
                choose: { _ = slashPicker.accept($0) },
                row: { command in
                    ConversationPickerRow(
                        name: command.name,
                        detail: command.summary,
                        symbol: "",
                        source: command.source,
                        help: command.argumentHint.map { "\(command.name) \($0)" } ?? command.summary
                    )
                }
            )
        } else if isShell, completesShell, shellCompleter.isShowing {
            ConversationPickerMenu(
                items: shellCompleter.rows,
                id: \.id,
                selected: shellCompleter.selectedID,
                label: "Shell completions",
                choose: { _ = shellCompleter.accept($0) },
                row: { row in
                    let item = row.item
                    return ConversationPickerRow(
                        name: item.name,
                        detail: item.description,
                        symbol: "chevron.right.square",
                        help: item.description.isEmpty ? item.name : item.description,
                        matches: item.matches,
                        isDangerous: item.isDangerous
                    )
                }
            )
        }
    }

    private func recallQueued() -> Bool {
        guard model.canRecallQueued else { return false }

        Task { await model.recallQueued() }
        return true
    }

    private func send() {
        let waiting = waiting
        Task {
            if let waiting { await model.decline(waitingFor: waiting.waitingFor, since: waiting.since) } else { await model.send() }
        }
    }
}

private struct ConversationComposerLayout: Layout {
    static let inset: CGFloat = 10
    static let controlSize: CGFloat = 24

    var fieldHeight: CGFloat
    let canAttach: Bool

    var animatableData: CGFloat {
        get { fieldHeight }
        set { fieldHeight = newValue }
    }

    static func fieldBounds(in width: CGFloat, canAttach: Bool) -> (leading: CGFloat, width: CGFloat) {
        let controlInset = controlSize + 2 * inset
        let leading: CGFloat = canAttach ? controlInset : 16
        return (leading, max(0, width - leading - controlInset))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        _ = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        return CGSize(width: width, height: max(fieldHeight, Self.controlSize) + 2 * Self.inset)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let field = Self.fieldBounds(in: bounds.width, canAttach: canAttach)
        let controlsInset = Self.inset
        let controlsTop = bounds.maxY - controlsInset - Self.controlSize
        subviews[0].place(at: CGPoint(x: bounds.minX + controlsInset, y: controlsTop), anchor: .topLeading, proposal: .unspecified)
        subviews[1].place(
            at: CGPoint(x: bounds.minX + field.leading, y: bounds.midY - fieldHeight / 2),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: field.width, height: fieldHeight)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX - controlsInset, y: controlsTop), anchor: .topTrailing, proposal: .unspecified)
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
                ConversationImageTag(number: number)
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
