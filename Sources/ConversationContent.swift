import AppKit
import BerthCore
import SwiftUI

let elapsedFormat = Duration.UnitsFormatStyle.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)

#if DEBUG
let conversationExpandsAll = UserDefaults.standard.bool(forKey: "snapshotConversationExpanded")
#else
let conversationExpandsAll = false
#endif

private let markerWidth = 16.0
private let collapsedDiffRows = 14

extension EnvironmentValues {
    @Entry var conversationFolder = ""
}

extension GhosttyTheme {
    func conversationFont(_ delta: Double = 0) -> Font {
        Font(NSFont(descriptor: font.fontDescriptor, size: font.pointSize + delta) ?? font)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let images = entry.images {
                HStack(spacing: 6) {
                    ForEach(images.enumerated(), id: \.offset) { index, data in
                        if let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 80)
                                .clipShape(.rect(cornerRadius: 8))
                                .accessibilityLabel("Image \(index + 1)")
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "❯")
                    .foregroundStyle(theme.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: entry.text)
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
        .lineSpacing(3)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.foreground.opacity(0.07), in: .rect(cornerRadius: 10))
        .opacity(isQueued ? 0.6 : 1)
        .contextMenu { Button("Copy") { copyToPasteboard(entry.text) } }
    }
}

struct ConversationReply: View {
    let text: String

    @Environment(\.ghosttyTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "●")
                .font(theme.conversationFont(-3))
                .foregroundStyle(theme.foreground)
                .frame(width: markerWidth - 8, alignment: .leading)
                .accessibilityHidden(true)
            ConversationMarkdown(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(text) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(theme.secondary)
                .help("Copy as Markdown")
                .opacity(isHovered ? 1 : 0)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy") { copyToPasteboard(String(MarkdownBlock.inline(text).characters)) }
            Button("Copy as Markdown") { copyToPasteboard(text) }
        }
    }
}

struct ConversationMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownBlock.blocks(in: text).enumerated(), id: \.offset) { _, block in
                ConversationMarkdownBlock(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

private struct ConversationMarkdownBlock: View {
    let block: MarkdownBlock

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let text = Text(styled(block.lines.joined(separator: "\n")))

        Group {
            switch block.kind {
            case .paragraph:
                text
                    .frame(maxWidth: .infinity, alignment: .leading)

            case let .heading(level):
                text
                    .font(theme.conversationFont(level == 1 ? 4 : level == 2 ? 2 : 1).bold())
                    .padding(.top, 6)

            case let .item(marker, depth):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker)
                        .foregroundStyle(theme.secondary)
                        .monospacedDigit()
                    text
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(depth) * 18 + 4)

            case let .code(language):
                ConversationCodeBlock(text: block.lines.joined(separator: "\n"), language: language)

            case .table:
                ConversationTable(lines: block.lines)
            }
        }
        .font(theme.conversationFont())
        .lineSpacing(3)
    }

    private func styled(_ source: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { attributed[run.range].backgroundColor = theme.foreground.opacity(0.1) }
            if run.link != nil { attributed[run.range].foregroundColor = theme.unread }
        }
        return attributed
    }
}

private struct ConversationTable: View {
    let lines: [String]

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let rows = lines
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { row in !row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }

        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                ForEach(rows.enumerated(), id: \.offset) { index, row in
                    GridRow {
                        ForEach(row.enumerated(), id: \.offset) { _, cell in
                            Text(MarkdownBlock.inline(cell))
                                .bold(index == 0)
                        }
                    }
                    if index < rows.count - 1 { Divider() }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(theme.foreground.opacity(0.05), in: .rect(cornerRadius: 10))
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
                    .lineSpacing(2)
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
    let state: ConversationToolState

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationFolder) private var folder
    @State private var isExpanded = conversationExpandsAll
    @State private var isHovered = false

    var body: some View {
        let summary = call.resultSummary
        let isError = summary?.isError == true
        let arguments = call.arguments.replacing("\(folder)/", with: "")
        let diff = diffRows
        let output = call.result?.text ?? ""
        let hasDetail = !output.isEmpty || call.use.command?.contains("\n") == true

        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(isError: isError)
                    Text("\(Text(verbatim: call.displayName).bold())\(Text(verbatim: arguments.isEmpty ? "" : "(\(arguments))").foregroundStyle(theme.secondary))")
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
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            .accessibilityHint(hasDetail ? "Shows the output" : "")
            statusLine(summary: summary, isError: isError)
            if !diff.isEmpty {
                ConversationDiff(rows: diff, language: call.use.filePath, isExpanded: isExpanded)
                    .padding(.leading, markerWidth + 8)
                    .padding(.top, 2)
            }
            if isExpanded, hasDetail {
                VStack(alignment: .leading, spacing: 6) {
                    if let command = call.use.command, command.contains("\n") { ConversationCodeBlock(text: command, syntax: "bash", maxHeight: 200) }
                    if !output.isEmpty, diff.isEmpty || isError { ConversationCodeBlock(text: output, tint: isError ? theme.closed : nil, maxHeight: 280) }
                }
                .padding(.leading, markerWidth + 8)
                .padding(.top, 4)
            }
        }
        .font(theme.conversationFont())
        .onHover { isHovered = $0 }
        .contextMenu {
            if let command = call.use.command { Button("Copy Command") { copyToPasteboard(command) } }
            if let path = call.use.filePath { Button("Copy Path") { copyToPasteboard(path) } }
            if let result = call.result, !result.text.isEmpty { Button("Copy Output") { copyToPasteboard(result.text) } }
        }
    }

    private var diffRows: [ToolDiffRow] {
        guard call.result?.isError == false else { return [] }

        if call.use.name == "Edit", let old = call.use.oldText, let new = call.use.newText { return ToolDiff.rows(old: old, new: new) }
        if call.use.name == "Write", let content = call.use.newText { return ToolDiff.rows(old: "", new: content) }
        return []
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

    @ViewBuilder
    private func statusLine(summary: ToolResultSummary?, isError: Bool) -> some View {
        if state != .finished || summary != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "⎿")
                    .foregroundStyle(theme.secondary)
                    .frame(width: markerWidth - 8, alignment: .leading)
                    .accessibilityHidden(true)
                if state == .waiting {
                    Text("Waiting for approval")
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
                .background(row.kind == .added ? theme.working.opacity(0.16) : row.kind == .removed ? theme.closed.opacity(0.16) : .clear)
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
        .padding(.vertical, 4)
        .background(theme.foreground.opacity(0.04), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.foreground.opacity(0.1)) }
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
        let tint = isError ? theme.closed : isRunning ? theme.working : theme.secondary
        let foreground = call.result?.date.flatMap { end in call.use.date.map { end.timeIntervalSince($0) } }.flatMap { $0 > 0 && !call.isAsyncLaunch && isAgent ? $0 : nil }

        HStack(spacing: 12) {
            Image(systemName: isError ? "xmark.circle" : isAgent ? "person.2" : "terminal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 8))
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
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.foreground.opacity(0.05), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(theme.foreground.opacity(0.08)) }
        .accessibilityElement(children: .combine)
        .contextMenu { Button("Copy Title") { copyToPasteboard(task?.title ?? call.cardTitle) } }
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
