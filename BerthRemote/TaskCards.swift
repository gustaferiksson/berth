import SwiftUI

struct TaskCard: View {
    let call: ToolCall
    let sessionID: String
    let live: LiveCall?

    @Environment(RemoteClient.self) private var client
    @State private var isShowingDetail = false

    var body: some View {
        let task = client.activity[sessionID]?.tasks.first { task in
            task.id == call.use.toolID || (call.use.date != nil && task.started == call.use.date && task.title == call.cardTitle)
        }
        let isAgent = call.kind == .agent
        let isError = call.result?.isError == true
        let isRunning = task != nil || (call.result == nil && live != nil)
        let since = task?.started ?? (call.result == nil ? call.use.date : nil)
        let foregroundDuration = call.result?.date.flatMap { end in call.use.date.map { end.timeIntervalSince($0) } }.flatMap { $0 > 0 && !call.isAsyncLaunch && isAgent ? $0 : nil }

        let card = HStack(alignment: .top, spacing: 12) {
            Image(systemName: live == .waiting(call.id) ? "exclamationmark.circle.fill" : isError ? "xmark.circle" : isAgent ? "person.2" : "terminal")
                .font(.body)
                .foregroundStyle(live == .waiting(call.id) ? .orange : isError ? .red : isAgent ? AgentTint.color(for: task?.title ?? call.cardTitle) : isRunning ? .green : .secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task?.title ?? call.cardTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                caption(task: task, isAgent: isAgent, since: since, duration: foregroundDuration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if task != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))

        if let task {
            Button { isShowingDetail = true } label: { card }
                .buttonStyle(.plain)
                .accessibilityHint("Shows what it is doing")
                .sheet(isPresented: $isShowingDetail) {
                    RunningSheet(sessionID: sessionID, taskID: task.id)
                }
        } else {
            card
                .accessibilityElement(children: .combine)
        }
    }

    private func caption(task: RemoteTask?, isAgent: Bool, since: Date?, duration: TimeInterval?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = since.map { Duration.seconds(max(0, context.date.timeIntervalSince($0)).rounded(.down)) } ?? duration.map { Duration.seconds($0.rounded()) }
            let parts: [Text] = [
                Text(task?.agentType ?? call.agentType ?? (isAgent ? "Agent" : "Shell")),
                task?.stats,
                elapsed.map { Text($0.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))).monospacedDigit() },
            ].compactMap(\.self)
            parts.dropFirst().reduce(parts[0]) { Text("\($0) · \($1)") }
        }
    }
}

struct TaskCards: View {
    let calls: [ToolCall]
    let sessionID: String
    let liveCall: LiveCall?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(calls) { call in
                TaskCard(call: call, sessionID: sessionID, live: call.id == liveCall?.id ? liveCall : nil)
            }
        }
    }
}

struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Duration.seconds(max(0, context.date.timeIntervalSince(since)).rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))
                .monospacedDigit()
        }
    }
}
