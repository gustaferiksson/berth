import SwiftUI

#if DEBUG
let expandsWork = UserDefaults.standard.bool(forKey: "snapshotExpanded")
let expandsCalls = UserDefaults.standard.bool(forKey: "snapshotExpandedCalls")
#else
let expandsWork = false
let expandsCalls = false
#endif

struct TurnView: View {
    let turn: Turn
    let isFinished: Bool
    let liveCall: LiveCall?

    @State private var showsWork = false
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth = 22

    var body: some View {
        let lastWork = turn.parts.lastIndex { if case .work = $0 { true } else { false } }
        let folded = isFinished && !turn.isInterrupted ? lastWork.map { turn.parts[...$0] } : nil

        VStack(alignment: .leading, spacing: 16) {
            if let prompt = turn.prompt {
                PromptBubble(entry: prompt)
            }
            if let folded {
                DisclosureGroup(isExpanded: $showsWork) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(folded) { TurnPartView(part: $0, liveCall: nil) }
                    }
                    .padding(.top, 12)
                } label: {
                    Label(turn.duration.map { "Worked for \($0.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))" } ?? "Worked", systemImage: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
            ForEach(turn.parts[(folded?.endIndex ?? 0)...]) { TurnPartView(part: $0, liveCall: liveCall) }
            if turn.isInterrupted {
                Label("Interrupted", systemImage: "stop.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .labelReservedIconWidth(iconWidth)
    }
}

private struct TurnPartView: View {
    let part: TurnPart
    let liveCall: LiveCall?

    var body: some View {
        switch part {
        case let .reply(entry):
            MarkdownText(text: entry.text)
        case let .work(calls):
            WorkGroupView(calls: calls, liveCall: liveCall)
        }
    }
}

private struct PromptBubble: View {
    let entry: RemoteEntry

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let images = entry.images {
                HStack(spacing: 6) {
                    ForEach(images.enumerated(), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 200, maxHeight: 120)
                                .clipShape(.rect(cornerRadius: 12))
                                .accessibilityLabel("Image \(index + 1)")
                        }
                    }
                }
            }
            if !entry.text.isEmpty {
                Text(verbatim: entry.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 19))
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MarkdownBlock.blocks(in: text).enumerated(), id: \.offset) { _, block in
                if block.kind == .prose {
                    Text(block.attributed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CodeBox(text: block.lines.joined(separator: "\n"))
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct MarkdownBlock {
    enum Kind { case prose, code, table }

    let kind: Kind
    var lines: [String]

    var attributed: AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            let heading = line.prefixMatch(of: /#{1,6}\s+/)
            let bullet = line.replacing(/^(\s*)[-*+]\s/, maxReplacements: 1) { "\($0.output.1)• " }
            let source = heading.map { String(line[$0.range.upperBound...]) } ?? bullet
            var rendered = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
            if heading != nil { rendered.font = .headline }
            result += index == 0 ? rendered : AttributedString("\n") + rendered
        }
        return result.transformingAttributes(\.link) { $0.value = nil }
    }

    static func blocks(in text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var isInFence = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInFence.toggle()
                if isInFence { blocks.append(MarkdownBlock(kind: .code, lines: [])) }
                continue
            }

            let kind: Kind = isInFence ? .code : trimmed.hasPrefix("|") ? .table : .prose
            if blocks.last?.kind == kind {
                blocks[blocks.count - 1].lines.append(line)
            } else if kind != .prose || !trimmed.isEmpty {
                blocks.append(MarkdownBlock(kind: kind, lines: [line]))
            }
        }
        return blocks.map { block in
            guard block.kind == .prose else { return block }
            let lines = block.lines.reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed()
            return MarkdownBlock(kind: .prose, lines: Array(lines))
        }
    }
}

struct CodeBox: View {
    let text: String
    var tint: Color?
    var maxHeight: CGFloat = .infinity

    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(maxHeight.isFinite ? [.horizontal, .vertical] : .horizontal) {
            Text(verbatim: text)
                .font(.footnote.monospaced())
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: maxHeight.isFinite ? min(height, maxHeight) : nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 10))
        .textSelection(.enabled)
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
        let verb = Text(live == nil ? call.verb.past : call.verb.present)
        let subject = Text(call.subject).font(call.kind == .command ? .subheadline.monospaced() : .subheadline)

        DisclosureGroup(isExpanded: $isExpanded) {
            ToolCallDetail(call: call)
                .padding(.top, 8)
        } label: {
            Label {
                Text("\(verb) \(subject)")
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
            } else if let detail = call.use.detail ?? (call.kind == .other ? call.use.text : nil) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let result = call.result, !result.text.isEmpty, call.kind != .edit || result.isError {
                CodeBox(text: result.text, tint: result.isError ? .red : nil, maxHeight: 240)
            }
        }
    }
}
