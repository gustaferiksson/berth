import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    let model: ConversationModel
    let harnessName: String
    let canAttach: Bool
    let isShell: Bool
    let isWorking: Bool
    let waiting: (waitingFor: String?, since: Double?)?
    let focusRequest: Int

    private static let tileSize = 56.0

    @Environment(\.ghosttyTheme) private var theme
    @State private var isImporting = false
    @State private var width: CGFloat = 0
    @State private var settledHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let draft = model.draft
        let stops = isWorking && draft.isEmpty
        let canSend = stops || !(draft.isEmpty || model.isSending)
        let font = isShell ? theme.font : NSFont.systemFont(ofSize: theme.font.pointSize)
        let singleRowWidth = ConversationComposerLayout.fieldBounds(in: width, isExpanded: false, canAttach: canAttach).width
        let isExpanded = !draft.files.isEmpty || draft.text.contains(where: \.isNewline) || width > 0 && (draft.text as NSString).size(withAttributes: [.font: font]).width > singleRowWidth
        let animation = reduceMotion ? nil : Animation.smooth(duration: 0.25)
        let inset = ConversationComposerLayout.inset
        let controlSize = ConversationComposerLayout.controlSize
        let fieldWidth = ConversationComposerLayout.fieldBounds(in: width, isExpanded: isExpanded, canAttach: canAttach).width
        let fieldHeight = ConversationComposerField.height(of: draft.text, font: font, width: fieldWidth)
        let animatesHeight = abs(fieldHeight - settledHeight) > controlSize * 1.5
        let shape = RoundedRectangle(cornerRadius: controlSize / 2 + inset)
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
                    ConversationComposerLayout(progress: isExpanded ? 1 : 0, fieldHeight: fieldHeight, canAttach: canAttach) {
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
                            promptColor: isShell ? NSColor(theme.shellAttached) : nil,
                            focusRequest: focusRequest,
                            layoutWidth: fieldWidth,
                            submit: send,
                            attach: { canAttach ? model.attach($0) : "" },
                            recall: recallQueued
                        )
                        Button {
                            guard stops else { return send() }

                            model.interrupt()
                        } label: {
                            Image(systemName: stops ? "stop.fill" : "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                                .frame(width: controlSize, height: controlSize)
                                .background(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .circle)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(canSend)
                        .accessibilityLabel(canSend ? (stops ? "Stop" : "Send") : "Send, unavailable")
                        .help(stops ? "Stop \(harnessName)" : waiting != nil ? "Deny and Send (↩)" : "Send (↩)")
                    }
                }
                .overlay { shape.strokeBorder(theme.shellAttached.opacity(0.6), lineWidth: 1).opacity(isShell ? 1 : 0).allowsHitTesting(false) }
                .glassEffect(.regular, in: shape)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .animation(animation, value: [isExpanded ? 1 : 0, animatesHeight ? fieldHeight : 0])
                .onChange(of: fieldHeight) { settledHeight = fieldHeight }
                .animation(.smooth(duration: 0.2), value: isShell)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.append((try? result.get()) ?? [])
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
    private static let expandedInset: CGFloat = 14
    private static let fieldTop: CGFloat = 12
    private static let fieldGap: CGFloat = 8

    var progress: CGFloat
    var fieldHeight: CGFloat
    let canAttach: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, fieldHeight) }
        set { (progress, fieldHeight) = (newValue.first, newValue.second) }
    }

    static func fieldBounds(in width: CGFloat, isExpanded: Bool, canAttach: Bool) -> (leading: CGFloat, width: CGFloat) {
        let controlInset = controlSize + 2 * inset
        let leading: CGFloat = isExpanded || !canAttach ? 16 : controlInset
        let trailing: CGFloat = isExpanded ? 16 : controlInset
        return (leading, max(0, width - leading - trailing))
    }

    private func blend(_ collapsed: CGFloat, _ expanded: CGFloat) -> CGFloat {
        collapsed + (expanded - collapsed) * progress
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        _ = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400
        let collapsed = max(fieldHeight, Self.controlSize) + 2 * Self.inset
        let expanded = Self.fieldTop + fieldHeight + Self.fieldGap + Self.controlSize + Self.expandedInset
        return CGSize(width: width, height: blend(collapsed, expanded))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let collapsed = Self.fieldBounds(in: bounds.width, isExpanded: false, canAttach: canAttach)
        let expanded = Self.fieldBounds(in: bounds.width, isExpanded: true, canAttach: canAttach)
        let controlsInset = blend(Self.inset, Self.expandedInset)
        let controlsTop = bounds.maxY - controlsInset - Self.controlSize
        subviews[0].place(at: CGPoint(x: bounds.minX + controlsInset, y: controlsTop), anchor: .topLeading, proposal: .unspecified)
        let fieldY = blend(bounds.midY - fieldHeight / 2, bounds.minY + Self.fieldTop)
        let roomAboveControls = max(0, controlsTop - Self.fieldGap - fieldY)
        subviews[1].place(
            at: CGPoint(x: bounds.minX + blend(collapsed.leading, expanded.leading), y: fieldY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: blend(collapsed.width, expanded.width), height: progress > 0 && fieldHeight > Self.controlSize ? min(fieldHeight, roomAboveControls) : fieldHeight)
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
