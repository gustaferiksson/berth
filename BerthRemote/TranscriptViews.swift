import SwiftUI
import UIKit

#if DEBUG
let expandsWork = UserDefaults.standard.bool(forKey: "snapshotExpanded")
let expandsCalls = UserDefaults.standard.bool(forKey: "snapshotExpandedCalls")
let focusesAndExpands = UserDefaults.standard.bool(forKey: "snapshotFocusAndExpand")
#else
let expandsWork = false
let expandsCalls = false
let focusesAndExpands = false
#endif

struct TurnView: View {
    let sessionID: String
    let turn: Turn
    let isFinished: Bool
    let isWorking: Bool
    let turnStartedAt: Date?
    let liveCall: LiveCall?
    let openChanges: (() -> Void)?

    @State private var showsWork = false
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth = 22

    var body: some View {
        let lastWork = turn.parts.lastIndex { if case .work = $0 { true } else { false } }
        let folded = isFinished && !turn.isInterrupted ? lastWork.map { turn.parts[...$0] } : nil
        let foldedCards = folded?.flatMap { part -> [ToolCall] in
            guard case let .cards(calls) = part else { return [] }

            return calls
        } ?? []

        VStack(alignment: .leading, spacing: 16) {
            if let prompt = turn.prompt {
                PromptBubble(entry: prompt)
            }
            if let folded {
                DisclosureGroup(isExpanded: $showsWork) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(folded.filter { !$0.isCards }) { TurnPartView(sessionID: sessionID, part: $0, liveCall: nil) }
                    }
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(width: 3)
                    }
                    .padding(.top, 12)
                } label: {
                    Label(turn.duration.map { "Worked for \($0.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))" } ?? "Worked", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
            if let folded, !showsWork {
                let refs = folded.flatMap { part -> [RemoteImageRef] in
                    guard case let .work(calls) = part else { return [] }

                    return calls.flatMap { $0.result?.imageRefs ?? [] }
                }
                if !refs.isEmpty { ToolImageRow(refs: refs) }
            }
            if !foldedCards.isEmpty {
                TaskCards(calls: foldedCards, sessionID: sessionID, liveCall: nil)
            }
            ForEach(turn.parts[(folded?.endIndex ?? 0)...]) { TurnPartView(sessionID: sessionID, part: $0, liveCall: liveCall) }
            if folded != nil, !turn.fileEdits.isEmpty {
                ChangedFilesCard(edits: turn.fileEdits, openChanges: openChanges)
            }
            if turn.isInterrupted {
                Label("Interrupted", systemImage: "stop.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if isWorking {
                WorkingStatus(since: turnStartedAt ?? turn.prompt?.date)
            }
        }
        .labelReservedIconWidth(iconWidth)
        #if DEBUG
        .task { await expandForSnapshot() }
        #endif
    }

    #if DEBUG
    private func expandForSnapshot() async {
        guard focusesAndExpands, isFinished else { return }

        try? await Task.sleep(for: .seconds(6))
        for _ in 0..<4 {
            showsWork.toggle()
            print("snapshotFocusAndExpand: \(turn.id) showsWork \(showsWork)")
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
    #endif
}

private struct WorkingStatus: View {
    let since: Date?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { context in
            Label {
                if let since {
                    Text("Working · \(Duration.seconds(max(0, context.date.timeIntervalSince(since)).rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
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
        .foregroundStyle(.secondary)
    }
}

struct QueuedPrompt: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            PromptBubble(entry: RemoteEntry(id: text, kind: .prompt, text: text), isQueued: true)
            Label("Queued", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct PendingPromptBubble: View {
    let prompt: PendingPrompt
    let attachments: [Attachment]
    let canRetry: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if attachments.isEmpty, let command = prompt.shellCommand {
                PromptBubble(entry: RemoteEntry(id: "", kind: .prompt, text: command, name: "bash", command: command), isShellRunning: !prompt.isFailed)
            } else {
                PromptBubble(entry: RemoteEntry(id: "", kind: .prompt, text: prompt.text), attachments: attachments)
                    .opacity(0.6)
            }
            if prompt.isFailed {
                HStack(spacing: 4) {
                    Text("Not sent")
                        .foregroundStyle(.secondary)
                    Button(action: retry) {
                        Text("Retry")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .disabled(!canRetry)
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .font(.footnote)
            }
        }
    }
}

private struct TurnPartView: View {
    let sessionID: String
    let part: TurnPart
    let liveCall: LiveCall?

    var body: some View {
        switch part {
        case let .reply(entry):
            MarkdownText(text: entry.text)
        case let .work(calls):
            WorkGroupView(calls: calls, liveCall: liveCall)
        case let .cards(calls):
            TaskCards(calls: calls, sessionID: sessionID, liveCall: liveCall)
        }
    }
}

private struct PromptBubble: View {
    let entry: RemoteEntry
    var isQueued = false
    var attachments: [Attachment]?
    var isShellRunning = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isExpanded = false
    @State private var viewerStart: ViewerImage?
    @ScaledMetric(relativeTo: .subheadline) private var markerWidth = 16
    @ScaledMetric(relativeTo: .caption2) private var imageTagDescent = 2.0

    var body: some View {
        if entry.name == "bash" { shell } else { promptBubble }
    }

    private var promptBubble: some View {
        let uploads = PendingPrompts.uploadPath
        let files = attachments?.filter { $0.thumbnail == nil }.map(\.name) ?? entry.text.matches(of: uploads).map { String($0.output.1) }
        let images = attachments?.compactMap(\.thumbnail) ?? entry.images ?? []
        let text = (attachments == nil ? entry.text.replacing(uploads, with: "") : entry.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = PromptTextPart.split(text)
        let numbers = imageNumbers(parts: parts, count: images.count)
        let viewerImages = images.enumerated().map { ViewerImage(id: String($0.offset), data: $0.element) }
        let showsText = !text.isEmpty && !(!images.isEmpty && text.replacing(PromptTextPart.imageToken, with: "").allSatisfy(\.isWhitespace))
        let bubble = UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 4, topTrailingRadius: 20, style: .continuous)

        return VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images.enumerated(), id: \.offset) { index, data in
                        let number = numbers[index]
                        if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
                            let scale = min(200 / image.size.width, 120 / image.size.height)
                            Button { viewerStart = viewerImages[index] } label: {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                                    PromptImageTag(number: number)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the image full screen")
                            .accessibilityLabel("Image \(String(number))")
                        }
                    }
                }
            }
            ForEach(files.enumerated(), id: \.offset) { _, name in
                Label(name, systemImage: "doc.fill")
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background { RoundedRectangle(cornerRadius: 14).fill(.fill.tertiary) }
            }
            if showsText {
                promptText(parts)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background { bubble.fill(.fill.tertiary) }
                    .textSelection(.enabled)
            }
        }
        .opacity(isQueued ? 0.6 : 1)
        .fullScreenCover(item: $viewerStart) { ImageViewer(images: viewerImages, start: $0) }
        .task { if UserDefaults.standard.bool(forKey: "snapshotOpenImageViewer") { viewerStart = viewerImages.first } }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in length * 0.85 }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func imageNumbers(parts: [PromptTextPart], count: Int) -> [Int] {
        if let numbers = entry.imageNumbers, numbers.count == count { return numbers }

        let references = parts.compactMap { part -> Int? in
            if case let .image(_, number) = part { return number }
            return nil
        }
        return references.count == count ? references : (0..<count).map { $0 + 1 }
    }

    private func promptText(_ parts: [PromptTextPart]) -> Text {
        parts.reduce(Text(verbatim: "")) { result, part in
            let text = switch part {
            case let .text(value): Text(verbatim: String(value))
            case let .image(token, number): inlineImageTag(token: token, number: number)
            case let .pasted(value): Text(verbatim: String(value)).font(.subheadline.monospaced()).foregroundStyle(.secondary)
            }
            return Text("\(result)\(text)")
        }
    }

    private func inlineImageTag(token: Substring, number: Int) -> Text {
        let renderer = ImageRenderer(content: PromptImageTag(number: number)
            .environment(\.colorScheme, colorScheme)
            .environment(\.dynamicTypeSize, dynamicTypeSize))
        renderer.scale = displayScale
        guard let image = renderer.uiImage else { return Text(verbatim: String(token)) }

        return Text(Image(uiImage: image).renderingMode(.original))
            .baselineOffset(-imageTagDescent - 2)
            .accessibilityLabel(Text("Image \(String(number))"))
    }

    private var shell: some View {
        let output = entry.shellOutput.map { $0.isEmpty ? [] : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        let errors = entry.shellError.map { $0.isEmpty ? [] : $0.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) } ?? []
        let lines = output.map { (text: $0, isError: false) } + errors.map { (text: $0, isError: true) }
        let moreLines = lines.count - 4

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "!")
                    .foregroundStyle(.secondary)
                    .frame(width: markerWidth, alignment: .leading)
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "⎿")
                        .foregroundStyle(.secondary)
                        .frame(width: markerWidth, alignment: .leading)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines.prefix(isExpanded ? lines.count : 4).enumerated(), id: \.offset) { _, line in
                            Text(verbatim: line.text.isEmpty ? " " : String(line.text))
                                .foregroundStyle(line.isError ? Color.red.opacity(0.8) : .secondary)
                                .textSelection(.enabled)
                        }
                        if moreLines > 0 {
                            Button { isExpanded.toggle() } label: {
                                Text(isExpanded ? "Show less" : "Show \(moreLines) more lines")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(minHeight: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(.leading, markerWidth)
            }
        }
        .font(.subheadline.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PromptImageTag: View {
    let number: Int

    var body: some View {
        Text(verbatim: "#\(number)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.systemBackground).opacity(0.85), in: .capsule)
    }
}

private struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownBlock.blocks(in: text).enumerated(), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        let text = Text(MarkdownBlock.inline(block.lines.joined(separator: "\n")))

        switch block.kind {
        case .paragraph:
            text
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level):
            text
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 6)

        case let .item(marker, depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 18)

        case let .code(language):
            CodeBox(text: block.lines.joined(separator: "\n"), language: language)

        case .table:
            MarkdownTable(lines: block.lines)
        }
    }
}

private struct MarkdownTable: View {
    let lines: [String]

    var body: some View {
        let rows = lines
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { row in !row.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }

        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(rows.enumerated(), id: \.offset) { index, row in
                    GridRow {
                        ForEach(row.enumerated(), id: \.offset) { _, cell in
                            Text(MarkdownBlock.inline(cell))
                                .bold(index == 0)
                        }
                    }
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .font(.subheadline)
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }
}

struct CodeBox: View {
    let text: String
    var language = ""
    var syntax: String?
    var tint: Color?
    var maxHeight: CGFloat = .infinity

    @AppStorage("conversationCodeSize") private var codeSize = "medium"
    @State private var height: CGFloat = 0
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                }
                ScrollView(maxHeight.isFinite ? [.horizontal, .vertical] : .horizontal) {
                    HighlightedText(text: text, language: syntax ?? language)
                        .font((codeSize == "small" ? Font.caption : codeSize == "large" ? .callout : .footnote).monospaced())
                        .lineSpacing(1)
                        .textSelection(.enabled)
                        .padding(12)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                }
                .frame(height: maxHeight.isFinite ? min(height, maxHeight) : nil)
                .scrollIndicators(.hidden)
            }

            Button {
                UIPasteboard.general.string = text
                isCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    isCopied = false
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCopied ? "Copied" : "Copy")
            .sensoryFeedback(.success, trigger: isCopied) { _, copied in copied }
        }
        .textSelection(.disabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 12))
    }
}

private struct WorkGroupView: View {
    let calls: [ToolCall]
    let liveCall: LiveCall?

    @State private var isExpanded = expandsWork

    var body: some View {
        let live = calls.last.flatMap { $0.id == liveCall?.id ? $0 : nil }
        let done = live == nil ? calls : Array(calls.dropLast())
        let kinds = Set(done.map(\.kind))

        VStack(alignment: .leading, spacing: 10) {
            if done.count > 1 {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(done) { ToolCallRow(call: $0, live: nil) }
                    }
                    .padding(.top, 10)
                    .padding(.leading, 12)
                } label: {
                    Label {
                        Text(ToolCall.summary(of: done))
                    } icon: {
                        Image(systemName: kinds.count == 1 ? kinds.first?.icon ?? "hammer" : "square.stack.3d.up")
                            .foregroundStyle(done.contains { $0.result?.isError == true } ? .red : .secondary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                if !isExpanded {
                    let refs = done.flatMap { $0.result?.imageRefs ?? [] }
                    if !refs.isEmpty { ToolImageRow(refs: refs) }
                }
            } else {
                ForEach(done) { ToolCallRow(call: $0, live: nil) }
            }
            if let live {
                ToolCallRow(call: live, live: liveCall)
            }
        }
        .tint(.secondary)
    }
}

private struct ToolCallRow: View {
    let call: ToolCall
    let live: LiveCall?

    @State private var isExpanded = expandsCalls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isError = call.result?.isError == true
        let isWaiting = live == .waiting(call.id)
        let verb = Text(live == nil ? call.verb.past : isWaiting ? (call.use.name == "AskUserQuestion" ? "Waiting for your answer" : "Waiting for approval") : call.verb.present)
        let separator = isWaiting ? " · " : " "
        let subject = Text(call.subject).font([.command, .read, .edit, .search, .other].contains(call.kind) ? .subheadline.monospaced() : .subheadline)
        let description = [.command, .agent].contains(call.kind) ? call.use.detail.flatMap { $0.isEmpty ? nil : $0 } : nil
        let fixed: String? = switch call.use.name {
        case "Poll": "Waiting"
        case "REPL": call.use.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "Running a script"
        default: nil
        }
        let title = fixed.map { Text(verbatim: $0) } ?? description.map { isWaiting ? Text("\(verb)\(separator)\($0)") : Text($0) } ?? Text("\(verb)\(separator)\(subject)")

        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $isExpanded) {
                ToolCallDetail(call: call)
                    .padding(.top, 8)
            } label: {
                Label {
                    title
                        .lineLimit(1)
                } icon: {
                    if case .running = live, !reduceMotion {
                        ProgressView()
                            .controlSize(.small)
                    } else if case .waiting = live {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: isError ? "xmark.circle" : call.kind.icon)
                            .foregroundStyle(isError ? .red : .secondary)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if let refs = call.result?.imageRefs {
                ToolImageRow(refs: refs)
            }
        }
    }
}

private struct ToolCallDetail: View {
    let call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command = call.use.command {
                CodeBox(text: command, syntax: "bash")
            } else if let newText = call.use.newText {
                VStack(spacing: 0) {
                    ForEach(EditHunk(old: call.use.oldText, new: newText).rows) { row in
                        DiffLine(row: row, highlighted: nil)
                    }
                }
                .background(.fill.quaternary)
                .clipShape(.rect(cornerRadius: 12))
            } else if call.kind != .agent, let detail = call.use.detail ?? (call.kind == .other ? call.use.text : nil) {
                Text(detail)
                    .font([.search, .web, .other].contains(call.kind) ? .footnote.monospaced() : .footnote)
                    .foregroundStyle(.secondary)
            }
            if let result = call.result, !result.text.isEmpty, call.kind != .edit || result.isError {
                CodeBox(text: result.text, tint: result.isError ? .red : nil, maxHeight: 240)
            }
        }
    }
}
