import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    let model: ConversationModel
    let harnessName: String
    let canAttach: Bool
    let isWorking: Bool
    let waiting: (waitingFor: String?, since: Double?)?
    let focusRequest: Int

    private static let tileSize = 56.0

    @Environment(\.ghosttyTheme) private var theme
    @State private var isImporting = false
    @State private var width: CGFloat = 0

    var body: some View {
        let draft = model.draft
        let stops = isWorking && draft.isEmpty
        let font = NSFont.systemFont(ofSize: theme.font.pointSize)
        let singleRowWidth = ConversationComposerLayout.fieldBounds(in: width, isExpanded: false, canAttach: canAttach).width
        let isExpanded = !draft.files.isEmpty || draft.text.contains(where: \.isNewline) || width > 0 && (draft.text as NSString).size(withAttributes: [.font: font]).width > singleRowWidth
        let inset = ConversationComposerLayout.inset
        let controlSize = ConversationComposerLayout.controlSize
        let placeholder = model.blocksSending ? "Wait for \(harnessName) to finish, or stop it" : waiting != nil ? "Decline with a message…" : isWorking ? "Queue for after this turn…" : "Message \(harnessName)"

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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileSize, maximum: Self.tileSize), spacing: inset)], alignment: .leading, spacing: inset) {
                            ForEach(draft.files, id: \.self) { file in
                                ConversationAttachmentTile(file: file, number: draft.numbers[file], size: Self.tileSize, radius: controlSize / 2) { model.remove(file) }
                            }
                        }
                        .padding([.horizontal, .top], inset)
                    }
                    ConversationComposerLayout(isExpanded: isExpanded, canAttach: canAttach) {
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
                            text: Binding { model.draft.text } set: { model.setText($0) },
                            placeholder: placeholder,
                            font: font,
                            color: NSColor(theme.foreground),
                            focusRequest: focusRequest,
                            submit: send,
                            attach: { canAttach ? model.attach($0) : "" }
                        )
                        if stops || !(draft.isEmpty || model.isSending) {
                            Button {
                                guard stops else { return send() }

                                model.interrupt()
                            } label: {
                                Image(systemName: stops ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: controlSize, height: controlSize)
                                    .background(Color.accentColor, in: .circle)
                                    .contentShape(.circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(stops ? "Stop" : "Send")
                            .help(stops ? "Stop \(harnessName)" : waiting != nil ? "Deny and Send (↩)" : "Send (↩)")
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .frame(width: controlSize, height: controlSize)
                                .background(.quaternary, in: .circle)
                                .accessibilityLabel("Send, unavailable")
                        }
                    }
                }
                .glassEffect(.regular, in: .rect(cornerRadius: controlSize / 2 + inset))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .animation(.smooth(duration: 0.2), value: isExpanded)
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
}

private struct ConversationComposerLayout: Layout {
    static let inset: CGFloat = 10
    static let controlSize: CGFloat = 24
    private static let fieldTop: CGFloat = 14

    let isExpanded: Bool
    let canAttach: Bool

    static func fieldBounds(in width: CGFloat, isExpanded: Bool, canAttach: Bool) -> (leading: CGFloat, width: CGFloat) {
        let controlInset = controlSize + 2 * inset
        let leading: CGFloat = isExpanded || !canAttach ? 16 : controlInset
        let trailing: CGFloat = isExpanded ? 16 : controlInset
        return (leading, max(0, width - leading - trailing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        let field = Self.fieldBounds(in: width, isExpanded: isExpanded, canAttach: canAttach)
        let fieldHeight = subviews[1].sizeThatFits(ProposedViewSize(width: field.width, height: nil)).height
        let height = isExpanded ? Self.fieldTop + fieldHeight + Self.controlSize : max(fieldHeight, Self.controlSize)
        return CGSize(width: width, height: height + 2 * Self.inset)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let field = Self.fieldBounds(in: bounds.width, isExpanded: isExpanded, canAttach: canAttach)
        let controlsTop = isExpanded ? bounds.maxY - Self.inset - Self.controlSize : bounds.midY - Self.controlSize / 2
        subviews[0].place(at: CGPoint(x: bounds.minX + Self.inset, y: controlsTop), anchor: .topLeading, proposal: .unspecified)
        subviews[1].place(
            at: CGPoint(x: bounds.minX + field.leading, y: isExpanded ? bounds.minY + Self.fieldTop : bounds.midY),
            anchor: isExpanded ? .topLeading : .leading,
            proposal: ProposedViewSize(width: field.width, height: nil)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX - Self.inset, y: controlsTop), anchor: .topTrailing, proposal: .unspecified)
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
