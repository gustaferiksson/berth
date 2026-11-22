import SwiftUI

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
            PromptBubble(entry: RemoteEntry(id: text, kind: .prompt, text: text))
                .opacity(0.6)
            Label("Queued", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

    var body: some View {
        let uploads = /@\S*\/RemoteUploads\/[0-9A-Fa-f-]{36}\/(\S+)/
        let files = entry.text.matches(of: uploads).map { String($0.output.1) }
        let text = entry.text.replacing(uploads, with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .trailing, spacing: 6) {
            if let images = entry.images {
                HStack(spacing: 6) {
                    ForEach(images.enumerated(), id: \.offset) { index, data in
                        if let image = UIImage(data: data), image.size.height > 0 {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: min(200, 120 * image.size.width / image.size.height), height: 120)
                                .clipShape(.rect(cornerRadius: 14))
                                .accessibilityLabel("Image \(index + 1)")
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
                    .background(.fill.tertiary, in: .rect(cornerRadius: 14))
            }
            if !text.isEmpty {
                Text(verbatim: text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 20))
                    .textSelection(.enabled)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in length * 0.85 }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
            .padding(14)
        }
        .scrollIndicators(.hidden)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
    }
}

private struct MarkdownBlock {
    enum Kind: Equatable {
        case paragraph, table
        case heading(Int)
        case item(String, depth: Int)
        case code(String)
    }

    let kind: Kind
    var lines: [String]

    static func inline(_ source: String) -> AttributedString {
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        return parsed.transformingAttributes(\.link) { $0.value = nil }
    }

    static func blocks(in text: String) -> [Self] {
        var blocks: [Self] = []
        var isInFence = false
        var continues = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInFence.toggle()
                if isInFence { blocks.append(Self(kind: .code(String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)), lines: [])) }
                continues = false
                continue
            }
            if isInFence {
                blocks[blocks.count - 1].lines.append(line)
                continue
            }

            if trimmed.isEmpty {
                continues = false
            } else if let heading = trimmed.prefixMatch(of: /(#{1,6})\s+/) {
                blocks.append(Self(kind: .heading(heading.output.1.count), lines: [String(trimmed[heading.range.upperBound...])]))
                continues = false
            } else if let item = line.prefixMatch(of: /(\s*)([-*+]|\d+[.)])\s+/) {
                let marker = String(item.output.2)
                blocks.append(Self(kind: .item(marker.first?.isNumber == true ? marker : "•", depth: item.output.1.count / 2), lines: [String(line[item.range.upperBound...])]))
                continues = true
            } else if trimmed.hasPrefix("|") {
                if blocks.last?.kind == .table { blocks[blocks.count - 1].lines.append(trimmed) } else { blocks.append(Self(kind: .table, lines: [trimmed])) }
                continues = false
            } else if continues {
                blocks[blocks.count - 1].lines.append(trimmed)
            } else {
                blocks.append(Self(kind: .paragraph, lines: [line]))
                continues = true
            }
        }
        return blocks
    }
}

struct CodeBox: View {
    let text: String
    var language = ""
    var tint: Color?
    var maxHeight: CGFloat = .infinity

    @AppStorage("conversationCodeSize") private var codeSize = "medium"
    @State private var height: CGFloat = 0
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            ScrollView(maxHeight.isFinite ? [.horizontal, .vertical] : .horizontal) {
                Text(verbatim: text)
                    .font((codeSize == "small" ? Font.caption : codeSize == "large" ? .callout : .footnote).monospaced())
                    .lineSpacing(1)
                    .padding(12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: maxHeight.isFinite ? min(height, maxHeight) : nil)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 12))
        .textSelection(.enabled)
        .overlay(alignment: .topTrailing) {
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCopied ? "Copied" : "Copy")
            .sensoryFeedback(.success, trigger: isCopied) { _, copied in copied }
        }
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
        let verb = Text(live == nil ? call.verb.past : isWaiting ? "Waiting for approval" : call.verb.present)
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
                        Image(systemName: "hand.raised")
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
                CodeBox(text: command)
            } else if call.use.oldText != nil || call.use.newText != nil {
                if let oldText = call.use.oldText {
                    CodeBox(text: oldText, tint: .red, maxHeight: 240)
                }
                if let newText = call.use.newText {
                    CodeBox(text: newText, tint: .green, maxHeight: 240)
                }
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
