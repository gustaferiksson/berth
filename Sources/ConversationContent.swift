import AppKit
import BerthCore
import QuickLookUI
import SwiftUI

let elapsedFormat = Duration.UnitsFormatStyle.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)

#if DEBUG
let conversationExpandsAll = UserDefaults.standard.bool(forKey: "snapshotConversationExpanded")
let conversationShowsTasks = UserDefaults.standard.bool(forKey: "snapshotConversationTasks")
#else
let conversationExpandsAll = false
let conversationShowsTasks = false
#endif

private let markerWidth = 16.0
private let collapsedDiffRows = 14

extension EnvironmentValues {
    @Entry var conversationFolder = ""
}

extension GhosttyTheme {
    func conversationNSFont(_ delta: Double = 0) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: font.pointSize + delta) ?? font
    }

    func conversationFont(_ delta: Double = 0) -> Font {
        Font(conversationNSFont(delta))
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct ConversationElapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Duration.seconds(max(0, context.date.timeIntervalSince(since)).rounded(.down)).formatted(elapsedFormat))
                .monospacedDigit()
        }
    }
}

struct ConversationPrompt: View {
    let entry: RemoteEntry
    var isQueued = false

    @Environment(\.ghosttyTheme) private var theme
    @State private var isExpanded = conversationExpandsAll

    var body: some View {
        if entry.name == "bash" { shell } else { promptBubble }
    }

    private var promptBubble: some View {
        let bubble = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 4, topTrailingRadius: 10, style: .continuous)

        return VStack(alignment: .leading, spacing: 8) {
            if let images = entry.images {
                HStack(spacing: 6) {
                    ForEach(images.enumerated(), id: \.offset) { index, data in
                        if let image = NSImage(data: data) {
                            Button { ConversationImagePreview.shared.show(data) } label: {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 80)
                                    .clipShape(.rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Image \(index + 1)")
                            .accessibilityHint("Opens a preview")
                            .contextMenu {
                                Button("Copy Image") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.writeObjects([image])
                                }
                                Button("Save Image…") { ConversationImagePreview.save(data) }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "❯")
                    .foregroundStyle(theme.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: entry.text)
                    .foregroundStyle(isQueued ? theme.secondary : theme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if isQueued {
                Label("Queued", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
            }
        }
        .font(theme.conversationFont())
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if isQueued {
                bubble.strokeBorder(theme.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            } else {
                bubble.fill(theme.foreground.opacity(0.07))
            }
        }
        .contextMenu { Button("Copy") { copyToPasteboard(entry.text) } }
    }

    private var shell: some View {
        let output = entry.shellOutput.map { $0.isEmpty ? [] : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        let errors = entry.shellError.map { $0.isEmpty ? [] : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        let lines = output.map { (text: $0, isError: false) } + errors.map { (text: $0, isError: true) }
        let moreLines = lines.count - 4

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "!")
                    .foregroundStyle(theme.secondary)
                    .frame(width: markerWidth - 8, alignment: .leading)
                    .accessibilityHidden(true)
                Text(verbatim: entry.text)
                    .textSelection(.enabled)
            }
            if !lines.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "⎿")
                        .foregroundStyle(theme.secondary)
                        .frame(width: markerWidth - 8, alignment: .leading)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines.prefix(isExpanded ? lines.count : 4).enumerated(), id: \.offset) { _, line in
                            Text(verbatim: line.text.isEmpty ? " " : String(line.text))
                                .foregroundStyle(line.isError ? theme.closed : theme.secondary)
                                .textSelection(.enabled)
                        }
                        if moreLines > 0 {
                            Button(isExpanded ? "Show less" : "Show \(moreLines) more lines") { isExpanded.toggle() }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                        }
                    }
                }
                .padding(.leading, markerWidth)
            }
        }
        .font(theme.conversationFont().monospaced())
        .foregroundStyle(theme.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
final class ConversationImagePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = ConversationImagePreview()

    private var url: URL?

    static func png(_ data: Data) -> Data {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
    }

    static func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Image.png"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        try? png(data).write(to: destination)
    }

    func show(_ data: Data) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ConversationImages", directoryHint: .isDirectory)
        let file = folder.appending(path: "\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? Self.png(data).write(to: file)) != nil else { return }

        #if DEBUG
        if UserDefaults.standard.bool(forKey: "snapshotConversation") { return print("snapshot quickLook \(file.path) \(Self.png(data).count) bytes") }
        #endif
        url = file
        guard let panel = QLPreviewPanel.shared() else { return }

        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel?) -> Int { 1 }

    nonisolated func previewPanel(_: QLPreviewPanel?, previewItemAt _: Int) -> (any QLPreviewItem)? {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

struct ConversationReply: View {
    let text: String

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "●")
                .font(theme.conversationFont(-3))
                .foregroundStyle(theme.foreground)
                .padding(.top, theme.conversationNSFont().ascender - theme.conversationNSFont(-3).ascender)
                .frame(width: markerWidth - 8, alignment: .leading)
                .accessibilityHidden(true)
            ConversationMarkdown(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button("Copy") { copyToPasteboard(String(MarkdownBlock.inline(text).characters)) }
            Button("Copy as Markdown") { copyToPasteboard(text) }
        }
    }
}

struct ConversationMarkdown: View {
    let text: String

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ConversationProse(run: ConversationMarkdownCache.run(text: text, theme: theme))
    }
}

private struct ConversationProse: View {
    let run: ConversationMarkdownCache.Run

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ConversationTextView(text: run.rendered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: ObjectIdentifier(run)) {
                let pending = run.codeBlocks.filter { !$0.language.isEmpty && run.highlighted[MarkdownAttributedString.highlightKey(language: $0.language, code: $0.code)] == nil }
                guard !pending.isEmpty else { return }

                for block in pending {
                    guard let colored = await ConversationHighlighting.highlighted(block.code, language: block.language, theme: theme) else { continue }

                    run.highlighted[MarkdownAttributedString.highlightKey(language: block.language, code: block.code)] = colored
                }
                run.rerender(theme: theme)
            }
    }
}

@MainActor
private enum ConversationMarkdownCache {
    @Observable
    final class Run {
        let blocks: [MarkdownBlock]
        let codeBlocks: [(language: String, code: String)]
        var highlighted: [String: NSAttributedString] = [:]
        private(set) var rendered: NSAttributedString

        init(blocks: [MarkdownBlock], theme: GhosttyTheme) {
            self.blocks = blocks
            codeBlocks = MarkdownAttributedString.codeBlocks(in: blocks)
            rendered = MarkdownAttributedString.render(blocks, theme: theme)
        }

        func rerender(theme: GhosttyTheme) {
            rendered = MarkdownAttributedString.render(blocks, theme: theme, highlighted: highlighted)
        }
    }

    private struct Key: Hashable {
        let text: String
        let foreground: Color
        let secondary: Color
        let unread: Color
        let inlineCode: Color
        let font: NSFont
    }

    private static var cached: [Key: Run] = [:]

    static func run(text: String, theme: GhosttyTheme) -> Run {
        let key = Key(text: text, foreground: theme.foreground, secondary: theme.secondary, unread: theme.unread, inlineCode: theme.inlineCode, font: theme.font)
        if let run = cached[key] { return run }

        let run = Run(blocks: MarkdownBlock.blocks(in: text), theme: theme)
        if cached.count >= 256 { cached.removeAll(keepingCapacity: true) }
        cached[key] = run
        return run
    }
}

struct ConversationCodeBlock: View {
    let text: String
    var language = ""
    var syntax: String?
    var tint: Color?
    var maxHeight = CGFloat.infinity

    @Environment(\.ghosttyTheme) private var theme
    @State private var height = 0.0
    @State private var isHovered = false
    @State private var isCopied = false

    var body: some View {
        let copy = Button(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc") {
            copyToPasteboard(text)
            isCopied = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(theme.secondary)
        .opacity(isHovered || isCopied ? 1 : 0)

        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                HStack {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                    Spacer()
                    copy
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            ScrollView(maxHeight.isFinite ? [.horizontal, .vertical] : .horizontal) {
                HighlightedConversationText(text: text, language: syntax ?? language)
                    .font(theme.conversationFont(-1))
                    .textSelection(.enabled)
                    .padding(12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: maxHeight.isFinite ? min(height, maxHeight) : nil)
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((tint ?? theme.foreground).opacity(tint == nil ? 0.06 : 0.12), in: .rect(cornerRadius: 10))
        .overlay(alignment: .topTrailing) {
            if language.isEmpty { copy.padding(8) }
        }
        .onHover { isHovered = $0 }
        .task(id: isCopied) {
            guard isCopied else { return }

            try? await Task.sleep(for: .seconds(1.5))
            isCopied = false
        }
    }
}

enum ConversationToolState {
    case finished, running, waiting
}

struct ConversationToolRow: View {
    let call: ToolCall
    let details: ToolCallDetails
    let state: ConversationToolState

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.conversationFolder) private var folder
    @State private var isExpanded = conversationExpandsAll

    var body: some View {
        let summary = details.summary
        let isError = summary?.isError == true
        let arguments = details.arguments.replacing("\(folder)/", with: "")
        let diff = details.diff
        let output = call.result?.text ?? ""
        let hasDetail = !output.isEmpty || call.use.command?.contains("\n") == true

        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                ConversationToolHeader(title: call.displayName, arguments: arguments, state: state, isError: isError, hasDetail: hasDetail, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            .accessibilityHint(hasDetail ? "Shows the output" : "")
            statusLine(summary: summary, isError: isError)
            if !diff.isEmpty {
                ConversationDiff(rows: diff, language: call.use.filePath, isExpanded: isExpanded)
                    .padding(.leading, markerWidth)
                    .padding(.top, 2)
            }
            if isExpanded, hasDetail {
                VStack(alignment: .leading, spacing: 6) {
                    if let command = call.use.command, command.contains("\n") { ConversationCodeBlock(text: command, syntax: "bash", maxHeight: 200) }
                    if !output.isEmpty, diff.isEmpty || isError { ConversationCodeBlock(text: output, tint: isError ? theme.closed : nil, maxHeight: 280) }
                }
                .padding(.leading, markerWidth)
                .padding(.top, 4)
            }
        }
        .font(theme.conversationFont())
        .contextMenu {
            if let command = call.use.command { Button("Copy Command") { copyToPasteboard(command) } }
            if let path = call.use.filePath { Button("Copy Path") { copyToPasteboard(path) } }
            if let result = call.result, !result.text.isEmpty { Button("Copy Output") { copyToPasteboard(result.text) } }
        }
    }

    @ViewBuilder
    private func statusLine(summary: ToolResultSummary?, isError: Bool) -> some View {
        if state != .finished || summary != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "⎿")
                    .foregroundStyle(theme.secondary)
                    .frame(width: markerWidth - 8, alignment: .leading)
                    .accessibilityHidden(true)
                if state == .waiting {
                    Text(call.use.name == "AskUserQuestion" ? "Waiting for your answer" : "Waiting for approval")
                        .foregroundStyle(theme.needsYou)
                } else if let summary {
                    Text("\(Text(verbatim: summary.text).foregroundStyle(isError ? theme.closed : theme.secondary))\(Text(verbatim: summary.moreLines > 0 ? " … +\(summary.moreLines) \(summary.moreLines == 1 ? "line" : "lines")" : "").foregroundStyle(theme.secondary.opacity(0.7)))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    HStack(spacing: 4) {
                        Text("Running")
                        if let started = call.use.date {
                            Text(verbatim: "·")
                            ConversationElapsed(since: started)
                        }
                    }
                    .foregroundStyle(theme.secondary)
                }
            }
            .padding(.leading, 0)
        }
    }
}

private struct ConversationToolHeader: View {
    let title: String
    let arguments: String
    let state: ConversationToolState
    let isError: Bool
    let hasDetail: Bool
    let isExpanded: Bool

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker(isError: isError)
            Text("\(Text(verbatim: title).bold())\(Text(verbatim: arguments.isEmpty ? "" : "(\(arguments))").foregroundStyle(theme.secondary))")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if hasDetail, isHovered || isExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func marker(isError: Bool) -> some View {
        let color = isError ? theme.closed : state == .waiting ? theme.needsYou : theme.working
        if state == .running, !reduceMotion {
            TimelineView(.periodic(from: .now, by: 0.6)) { context in
                Text(verbatim: "●")
                    .opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.6).isMultiple(of: 2) ? 1 : 0.35)
            }
            .font(theme.conversationFont(-3))
            .foregroundStyle(color)
            .frame(width: markerWidth - 8, alignment: .leading)
            .accessibilityLabel("Running")
        } else {
            Text(verbatim: "●")
                .font(theme.conversationFont(-3))
                .foregroundStyle(state == .finished && !isError ? theme.working : color)
                .frame(width: markerWidth - 8, alignment: .leading)
                .accessibilityLabel(isError ? "Failed" : state == .waiting ? "Waiting" : "Done")
        }
    }
}

struct ConversationDiff: View {
    let rows: [ToolDiffRow]
    let language: String?
    let isExpanded: Bool

    @Environment(\.ghosttyTheme) private var theme
    @State private var showsAll = false
    @State private var highlighted: [AttributedString] = []

    var body: some View {
        let limit = isExpanded || showsAll ? rows.count : collapsedDiffRows
        let shown = rows.prefix(limit)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                        .foregroundStyle(row.kind == .added ? theme.working : row.kind == .removed ? theme.closed : theme.secondary)
                        .frame(width: 10)
                    Text(highlighted.indices.contains(row.id) ? highlighted[row.id] : AttributedString(row.text.isEmpty ? " " : row.text))
                        .foregroundStyle(row.kind == .context ? theme.secondary : theme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background { Rectangle().fill(row.kind == .added ? theme.working.opacity(0.16) : row.kind == .removed ? theme.closed.opacity(0.16) : .clear) }
            }
            if rows.count > limit {
                Button("Show \(rows.count - limit) more lines") { showsAll = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .font(theme.conversationFont(-1))
        .textSelection(.enabled)
        .task(id: ["\(rows.count)", language ?? "", "\(theme.foreground)"]) {
            let input = rows.map { (old: $0.kind != .added, new: $0.kind != .removed, text: $0.text) }
            highlighted = await ConversationHighlighting.diffLines(input, language: language, theme: theme)
        }
        .background(theme.foreground.opacity(0.04), in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.foreground.opacity(0.1)) }
    }
}

struct ConversationTaskRow: View {
    let call: ToolCall
    let task: RemoteTask?

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isAgent = call.kind == .agent
        let isError = call.result?.isError == true
        let isRunning = task != nil
        let title = task?.title ?? call.cardTitle
        let tint = isError ? theme.closed : isAgent ? AgentTint.color(for: title) : isRunning ? theme.working : theme.secondary
        let foreground = call.result?.date.flatMap { end in call.use.date.map { end.timeIntervalSince($0) } }.flatMap { $0 > 0 && !call.isAsyncLaunch && isAgent ? $0 : nil }

        ConversationAgentButton(isAgent: isAgent, agentID: call.agentID, toolUseID: call.use.toolID, title: task?.title ?? call.cardTitle) {
            HStack(spacing: 12) {
                Image(systemName: isError ? "xmark.circle" : isAgent ? "person.2" : "terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: task?.title ?? call.cardTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    caption(foreground: foreground)
                        .font(.caption)
                        .foregroundStyle(theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isRunning, !reduceMotion {
                    ConversationSpinner()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.foreground.opacity(0.05), in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.foreground.opacity(0.08)) }
            .accessibilityElement(children: .combine)
            .padding(.leading, markerWidth)
            .contextMenu { Button("Copy Title") { copyToPasteboard(task?.title ?? call.cardTitle) } }
        }
    }

    private func caption(foreground: TimeInterval?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = task.map { Duration.seconds(max(0, context.date.timeIntervalSince($0.started)).rounded(.down)) } ?? foreground.map { Duration.seconds($0.rounded()) }
            let parts = [
                task?.agentType ?? call.agentType ?? (call.kind == .agent ? "Agent" : "Shell"),
                task?.toolCount.map { "\($0) tool \($0 == 1 ? "use" : "uses")" },
                task?.tokens.map { "\($0.formatted(.number.notation(.compactName))) tokens" },
                elapsed?.formatted(elapsedFormat),
            ].compactMap(\.self)
            Text(verbatim: parts.joined(separator: " · "))
                .monospacedDigit()
        }
    }
}

struct ConversationSpinner: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel("Loading")
    }
}
