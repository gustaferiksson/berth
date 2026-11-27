import AppKit
import BerthCore
import ImageIO
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

let elapsedFormat = Duration.UnitsFormatStyle.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)

#if DEBUG
let conversationExpandsAll = UserDefaults.standard.bool(forKey: "snapshotConversationExpanded")
let conversationShowsTasks = UserDefaults.standard.bool(forKey: "snapshotConversationTasks")
let conversationShowsTasksExpanded = UserDefaults.standard.bool(forKey: "snapshotConversationTasksExpanded")
#else
let conversationExpandsAll = false
let conversationShowsTasks = false
let conversationShowsTasksExpanded = false
#endif

private let markerWidth = 16.0
private let collapsedDiffRows = 14

extension EnvironmentValues {
    @Entry var conversationFolder = ""
    @Entry var promptImageLoader = PromptImageLoader { _, _ in nil }
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

struct PromptImageLoader {
    let load: @MainActor (String, Int) async -> Data?

    @MainActor
    func callAsFunction(_ entryID: String, _ index: Int) async -> Data? {
        await load(entryID, index)
    }
}

struct ConversationPrompt: View {
    let entry: RemoteEntry
    var selectionID: String?
    var expansionID: String?
    var isShellRunning = false

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationFolder) private var folder
    @Environment(\.conversationExpansion) private var expansion
    @State private var isExpanded = conversationExpandsAll

    var body: some View {
        if entry.name == "bash" { shell } else { promptBubble }
    }

    private var promptBubble: some View {
        let bubble = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 2, topTrailingRadius: 10, style: .continuous)

        let hasImages = entry.images?.isEmpty == false
        let numbers = entry.imageNumbers ?? Array(1...max(entry.images?.count ?? 0, 1))
        let mentions = PromptMentions.resolve(entry.text, folder: folder)
        let prose = hasImages ? PromptTextPart.removingImageTags(numbers, from: mentions.text) : mentions.text
        let showsText = prose.contains { !$0.isWhitespace }

        return VStack(alignment: .trailing, spacing: 6) {
            if !mentions.thumbnails.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(mentions.thumbnails) { ConversationMentionCard(thumbnail: $0) }
                }
            }
            if let images = entry.images {
                FlowLayout {
                    ForEach(images.enumerated(), id: \.offset) { index, data in
                        ConversationPromptImage(entryID: entry.id, thumbnail: data, index: index, number: numbers[index])
                    }
                }
            }
            if showsText {
                let itemID = selectionID ?? expansionID
                ConversationTextView(text: Self.attributed(mentions, theme: theme, displayScale: displayScale, colorScheme: colorScheme, itemID: itemID, expanded: expansion?.keys ?? []), selectionID: selectionID, sizing: .hug)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(bubble.fill(theme.foreground.opacity(0.07)))
                    .contextMenu { Button("Copy") { copyToPasteboard(PromptTextPart.plain(entry.text)) } }
            }
        }
        .frame(maxWidth: theme.messageWidth * 0.75, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    static var fence: Regex<(Substring, Substring, Substring, Substring?)> {
        /(?m)^[\t ]*```([^\r\n]*)(?:\R|\z)((?s:.*?))(?:(^[\t ]*```[\t ]*(?:\R|\z))|\z)/
    }

    private struct Segment {
        let raw: Substring
        let rendered: NSAttributedString
        let lineCount: Int
        let isCode: Bool
    }

    static func attributed(_ mentions: PromptMentions.Result, theme: GhosttyTheme, displayScale: CGFloat? = nil, colorScheme: ColorScheme = .light, itemID: String? = nil, expanded: Set<String> = []) -> NSAttributedString {
        let text = mentions.text
        let font = theme.conversationNSFont()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = (font.ascender - font.descender + font.leading) * (theme.lineHeightMultiple - 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(theme.foreground), .paragraphStyle: style]
        var occurrences = mentions.occurrences[...]
        let prose = { (raw: Substring) -> Segment in
            let rendered = attributedProse(raw, occurrences: &occurrences, attributes: attributes, font: font, theme: theme, displayScale: displayScale, colorScheme: colorScheme)
            let lines = rendered.string.count(where: \.isNewline) + (rendered.string.last?.isNewline == false ? 1 : 0)
            return Segment(raw: raw, rendered: rendered, lineCount: lines, isCode: false)
        }
        var segments: [Segment] = []
        var start = text.startIndex
        for (index, match) in text.matches(of: fence).enumerated() {
            if start < match.range.lowerBound { segments.append(prose(text[start..<match.range.lowerBound])) }
            let language = match.output.1.trimmingCharacters(in: .whitespaces)
            let body = match.output.2
            let code = String(match.output.3 != nil && body.last?.isNewline == true ? body.dropLast() : body)
            let key = itemID.map { "\($0)#code\(index)" }
            let units = MarkdownAttributedString.codeUnits(code, language: language, theme: theme, key: key, expanded: expanded)
            let lines = code.count(where: \.isNewline) + 1
            let lineCount = key == nil ? lines : min(lines, MarkdownAttributedString.codeLineLimit + 1)
            segments.append(Segment(raw: match.output.0, rendered: MarkdownAttributedString.assemble(units), lineCount: lineCount, isCode: true))
            start = match.range.upperBound
        }
        if start < text.endIndex { segments.append(prose(text[start...])) }

        let lineLimit = 20
        let total = segments.reduce(0) { $0 + $1.lineCount }
        let key = itemID.flatMap { total > lineLimit ? "\($0)#bubble" : nil }
        let isCollapsed = key.map { !expanded.contains($0) } ?? false
        let result = NSMutableAttributedString()
        var visible = 0
        var hidden = ""
        for (index, segment) in segments.enumerated() {
            let remaining = lineLimit - visible
            if isCollapsed, index > 0, remaining == 0 || segment.isCode && segment.lineCount > remaining {
                hidden = String(text[segment.raw.startIndex...])
                break
            }
            if isCollapsed, !segment.isCode, segment.lineCount > remaining {
                let rendered = segment.rendered.string
                let end = rendered.indices.lazy.filter { rendered[$0].isNewline }.prefix(remaining).last!
                let pasted = segment.raw.matches(of: PromptTextPart.pastedBlock)
                let visibleBreaks = segment.raw.indices.lazy.filter { index in
                    guard segment.raw[index].isNewline else { return false }
                    guard let match = pasted.first(where: { $0.range.contains(index) }) else { return true }

                    let interior = match.output.1
                    return interior.firstIndex(where: { !$0.isNewline }).map { $0 < index && index < interior.lastIndex { !$0.isNewline }! } ?? false
                }
                if let lastBreak = visibleBreaks.prefix(remaining).last {
                    hidden = String(text[text.index(after: lastBreak)...])
                }
                result.append(segment.rendered.attributedSubstring(from: NSRange(rendered.startIndex..<end, in: rendered)))
                visible += remaining
                break
            }
            result.append(segment.rendered)
            visible += segment.lineCount
            if segment.isCode, index < segments.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        }
        if let key {
            if result.string.last?.isNewline == true {
                if isCollapsed {
                    let newline = result.string.index(before: result.string.endIndex)
                    result.addAttribute(.conversationCopyText, value: "", range: NSRange(newline..., in: result.string))
                }
            } else {
                result.append(NSAttributedString(string: "\n", attributes: attributes.merging([.conversationCopyText: ""]) { $1 }))
            }
            let title = isCollapsed ? "Show \(total - visible) more lines" : "Show less"
            result.append(MarkdownAttributedString.expansionLink(title, key: key, copyText: isCollapsed ? "\n" + hidden : "", attributes: attributes, color: NSColor(theme.secondary)))
        }
        return result
    }

    private static func attributedProse(_ text: Substring, occurrences: inout ArraySlice<FileMentions.Occurrence>, attributes: [NSAttributedString.Key: Any], font: NSFont, theme: GhosttyTheme, displayScale: CGFloat?, colorScheme: ColorScheme) -> NSAttributedString {
        let scale = font.pointSize / NSFont.systemFontSize
        let result = NSMutableAttributedString()
        for part in PromptTextPart.split(text) {
            switch part {
            case let .text(value):
                var start = value.startIndex
                while let occurrence = occurrences.first, occurrence.token.startIndex < value.endIndex {
                    let token = occurrence.token
                    let mention = occurrence.mention
                    result.append(NSAttributedString(string: String(value[start..<token.startIndex]), attributes: attributes))

                    let attachment = NSTextAttachment()
                    attachment.attachmentCell = nil
                    if let displayScale {
                        let tag = ConversationMentionTag(mention: mention, scale: scale, foreground: theme.foreground)
                        attachment.image = tag.image(displayScale: displayScale, colorScheme: colorScheme)
                        attachment.bounds = NSRect(origin: NSPoint(x: 0, y: tag.baselineOffset), size: attachment.image?.size ?? .zero)
                    }
                    var tagAttributes = attributes
                    tagAttributes[.conversationCopyText] = String(token)
                    tagAttributes[.toolTip] = mention.path + (mention.exists ? "" : " (missing)")
                    if mention.exists {
                        var url = URLComponents()
                        url.scheme = PromptMentions.linkScheme
                        url.host = "file"
                        url.path = mention.path
                        tagAttributes[.link] = url.url
                    }
                    let tagText = NSMutableAttributedString(attachment: attachment)
                    tagText.addAttributes(tagAttributes, range: NSRange(location: 0, length: tagText.length))
                    result.append(tagText)
                    start = token.endIndex
                    occurrences = occurrences.dropFirst()
                }
                result.append(NSAttributedString(string: String(value[start...]), attributes: attributes))

            case let .image(token, number):
                let attachment = NSTextAttachment()
                if let displayScale {
                    let tag = ConversationImageTag(number: number, scale: scale)
                    attachment.image = tag.image(displayScale: displayScale)
                    attachment.bounds = NSRect(origin: NSPoint(x: 0, y: tag.baselineOffset), size: attachment.image?.size ?? .zero)
                }
                let tagText = NSMutableAttributedString(attachment: attachment)
                tagText.addAttributes(attributes.merging([.conversationCopyText: String(token)]) { $1 }, range: NSRange(location: 0, length: tagText.length))
                result.append(tagText)

            case let .pasted(value):
                let quoted = attributes.merging([
                    .font: NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular),
                    .foregroundColor: NSColor(theme.foreground).withAlphaComponent(0.75),
                    .backgroundColor: NSColor(theme.foreground).withAlphaComponent(0.08),
                ]) { $1 }
                result.append(NSAttributedString(string: String(value), attributes: quoted))
            }
        }
        return result
    }

    private var shell: some View {
        let output = entry.shellOutput.map { $0.isEmpty ? [] : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        let errors = entry.shellError.map { $0.isEmpty ? [] : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        let lines = output.map { (text: $0, isError: false) } + errors.map { (text: $0, isError: true) }
        let moreLines = lines.count - 4

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "!")
                    .foregroundStyle(theme.shellAttached)
                    .fixedSize()
                    .frame(width: markerWidth - 8, alignment: .leading)
                    .accessibilityHidden(true)
                Text(verbatim: entry.text)
                    .textSelection(.enabled)
                if isShellRunning, entry.shellOutput == nil, entry.shellError == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Running")
                }
            }
            if !lines.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "⎿")
                        .foregroundStyle(theme.secondary)
                        .fixedSize()
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
                                .pointerStyle(.link)
                                .font(.caption)
                                .foregroundStyle(theme.secondary)
                        }
                    }
                }
                .padding(.leading, markerWidth)
            }
        }
        .font(Font(theme.conversationCodeNSFont()))
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

    func showFile(_ file: URL) {
        present(file, size: 0)
    }

    func showOriginal(_ data: Data) {
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }.flatMap { UTType($0) }
        let file = cacheFolder.appending(path: "\(UUID().uuidString).\(type?.preferredFilenameExtension ?? "png")")
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        guard (try? data.write(to: file)) != nil else { return }

        present(file, size: data.count)
    }

    private var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ConversationImages", directoryHint: .isDirectory)
    }

    private func present(_ file: URL, size: Int) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "snapshotConversation") { return print("snapshot quickLook \(file.path) \(size) bytes") }
        #endif
        url = file
        guard let panel = QLPreviewPanel.shared() else { return }

        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func show(_ data: Data) {
        let file = cacheFolder.appending(path: "\(UUID().uuidString).png")
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let png = Self.png(data)
        guard (try? png.write(to: file)) != nil else { return }

        present(file, size: png.count)
    }

    nonisolated func numberOfPreviewItems(in _: QLPreviewPanel?) -> Int { 1 }

    nonisolated func previewPanel(_: QLPreviewPanel?, previewItemAt _: Int) -> (any QLPreviewItem)? {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

struct ConversationReply: View {
    let text: String
    let selectionID: String
    var isError = false

    @Environment(\.ghosttyTheme) private var theme

    private var warningTheme: GhosttyTheme {
        var themed = theme
        themed.foreground = theme.warning
        return themed
    }

    var body: some View {
        let replyTheme = isError ? warningTheme : theme
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "●")
                .font(theme.conversationFont(-3))
                .foregroundStyle(replyTheme.foreground)
                .fixedSize()
                .padding(.top, theme.conversationNSFont().ascender - theme.conversationNSFont(-3).ascender)
                .frame(width: markerWidth - 8, alignment: .leading)
                .accessibilityLabel("Warning")
                .accessibilityHidden(!isError)
            ConversationMarkdown(text: text, selectionID: selectionID)
                .environment(\.ghosttyTheme, replyTheme)
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
    var selectionID: String?

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.conversationExpansion) private var expansion
    @AppStorage(ReviewStyle.colorSchemeKey) private var colorScheme = ReviewColorScheme.terminal
    @AppStorage(ReviewStyle.syntaxColorsKey) private var syntaxColors = SyntaxColorSource.terminal

    var body: some View {
        ConversationProse(run: ConversationMarkdownCache.run(text: text, theme: theme, itemID: selectionID, expanded: expansion?.keys ?? [], palette: [colorScheme.rawValue, syntaxColors.rawValue]), selectionID: selectionID)
    }

    static func rendered(_ text: String, theme: GhosttyTheme, itemID: String, expanded: Set<String>) -> NSAttributedString {
        ConversationMarkdownCache.run(text: text, theme: theme, itemID: itemID, expanded: expanded).rendered
    }
}

private struct ConversationProse: View {
    let run: ConversationMarkdownCache.Run
    let selectionID: String?

    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        ConversationTextView(text: run.rendered, selectionID: selectionID)
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
        let itemID: String?
        let expanded: Set<String>
        var highlighted: [String: NSAttributedString] = [:]
        private(set) var rendered: NSAttributedString

        init(blocks: [MarkdownBlock], theme: GhosttyTheme, itemID: String?, expanded: Set<String>) {
            self.blocks = blocks
            self.itemID = itemID
            self.expanded = expanded
            codeBlocks = MarkdownAttributedString.codeBlocks(in: blocks)
            rendered = MarkdownAttributedString.render(blocks, theme: theme, itemID: itemID, expanded: expanded)
        }

        func rerender(theme: GhosttyTheme) {
            rendered = MarkdownAttributedString.render(blocks, theme: theme, highlighted: highlighted, itemID: itemID, expanded: expanded)
        }
    }

    private struct Key: Hashable {
        let text: String
        let foreground: Color
        let secondary: Color
        let unread: Color
        let inlineCode: Color
        let font: NSFont
        let codeFont: NSFont
        let lineHeightMultiple: CGFloat
        let palette: [String]
        let itemID: String?
        let expanded: Set<String>
    }

    private static var cached: [Key: Run] = [:]

    static func run(text: String, theme: GhosttyTheme, itemID: String?, expanded: Set<String>, palette: [String] = [ReviewStyle.colorSchemeKey, ReviewStyle.syntaxColorsKey, ReviewStyle.fontFamilyKey, ReviewStyle.fontSizeKey, ReviewStyle.lineHeightKey].map { UserDefaults.standard.object(forKey: $0).map { "\($0)" } ?? "" }) -> Run {
        let relevant: Set<String> = itemID.map { id in Set(expanded.filter { $0.hasPrefix(id + "#code") }) } ?? []
        let key = Key(text: text, foreground: theme.foreground, secondary: theme.secondary, unread: theme.unread, inlineCode: theme.inlineCode, font: theme.font, codeFont: theme.codeFont, lineHeightMultiple: theme.lineHeightMultiple, palette: palette, itemID: itemID, expanded: relevant)
        if let run = cached[key] { return run }

        let run = Run(blocks: MarkdownBlock.blocks(in: text), theme: theme, itemID: itemID, expanded: relevant)
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
                    .font(Font(theme.conversationCodeNSFont(-1)))
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
                    .pointerStyle(.link)
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .font(Font(theme.conversationCodeNSFont(-1)))
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
    @Environment(Store.self) private var store

    var body: some View {
        let stoppable = task.flatMap { store.backgroundTask(matching: $0.id) }.flatMap { background in store.subagentStop(for: background).map { (background, $0) } }
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
            .padding(.trailing, stoppable == nil ? 0 : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.foreground.opacity(0.05), in: .rect(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(theme.foreground.opacity(0.08)) }
            .accessibilityElement(children: .combine)
            .padding(.leading, markerWidth)
            .contextMenu {
                Button("Copy Title") { copyToPasteboard(task?.title ?? call.cardTitle) }
                if let (background, mode) = stoppable { Button(mode.title, systemImage: "stop.fill") { store.stopSubagent(background) } }
            }
        }
        .overlay(alignment: .trailing) {
            if let (background, mode) = stoppable {
                Button(mode.title, systemImage: "stop.fill") { store.stopSubagent(background) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(mode.title)
                    .padding(.trailing, 14)
            }
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

struct ConversationImageTag: View {
    let number: Int
    var scale: CGFloat = 1

    private var font: NSFont {
        let size = NSFont.preferredFont(forTextStyle: .caption2, options: [:]).pointSize
        return .systemFont(ofSize: size * scale, weight: .bold)
    }

    var body: some View {
        Text(verbatim: "#\(number)")
            .font(scale == 1 ? .caption2.weight(.bold) : Font(font))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, 2 * scale)
            .background(.black.opacity(0.6), in: .capsule)
    }

    var baselineOffset: CGFloat {
        font.descender - 2 * scale
    }

    @MainActor
    func image(displayScale: CGFloat) -> NSImage? {
        let key = "\(number)@\(scale)@\(displayScale)" as NSString
        if let cached = Self.images.object(forKey: key) { return cached }

        let renderer = ImageRenderer(content: self)
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return nil }

        Self.images.setObject(image, forKey: key)
        return image
    }

    @MainActor private static let images = NSCache<NSString, NSImage>()
}

private struct ConversationPromptImage: View {
    let entryID: String
    let thumbnail: Data
    let index: Int
    let number: Int

    @Environment(\.displayScale) private var displayScale
    @Environment(\.promptImageLoader) private var loadOriginal
    @State private var image: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Button {
            Task {
                guard let original = await loadOriginal(entryID, index) else { return ConversationImagePreview.shared.show(thumbnail) }

                ConversationImagePreview.shared.showOriginal(original)
            }
        } label: {
            Group {
                if let image {
                    let scale = min(240 / image.size.width, 120 / image.size.height)
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                } else {
                    Color.clear
                        .frame(width: 160, height: 120)
                }
            }
            .overlay(alignment: .bottomLeading) {
                ConversationImageTag(number: number)
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel("Image \(number)")
        .accessibilityHint("Opens a preview")
        .contextMenu {
            Button("Copy Image") {
                Task {
                    guard let image = await NSImage(data: loadOriginal(entryID, index) ?? thumbnail) else { return }

                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            Button("Save Image…") {
                Task { await ConversationImagePreview.save(loadOriginal(entryID, index) ?? thumbnail) }
            }
        }
        .task(id: "\(entryID)#\(index)@\(displayScale)") {
            let key = "\(entryID)#\(index)@\(displayScale)" as NSString
            if let cached = Self.cache.object(forKey: key) { return image = cached }

            let scale = displayScale
            let source = await loadOriginal(entryID, index) ?? thumbnail
            guard let decoded = await Task.detached(operation: { Self.downsampled(source, scale: scale) }).value else { return }

            Self.cache.setObject(decoded, forKey: key)
            image = decoded
        }
    }

    private nonisolated static func downsampled(_ data: Data, scale: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240 * scale,
              ] as CFDictionary)
        else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }
}
