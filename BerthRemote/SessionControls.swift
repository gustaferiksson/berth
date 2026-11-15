import SwiftUI

struct SessionControls: View {
    let session: RemoteSession?
    let sessionID: String
    let turnStart: Date?
    let pendingCall: ToolCall?
    let isAtBottom: Bool
    let scrollToEnd: () -> Void

    var body: some View {
        let isWorking = session?.status == "busy"

        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                if isWorking || !isAtBottom {
                    ZStack(alignment: .trailing) {
                        if isWorking {
                            WorkingCapsule(since: turnStart)
                                .frame(maxWidth: .infinity)
                        }
                        if !isAtBottom {
                            Button("Scroll to End", systemImage: "arrow.down", action: scrollToEnd)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
                                .controlSize(.large)
                        }
                    }
                }
                if let session, session.isLocked {
                    Label("Running in another terminal, so read-only here.", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else if let session, session.status == "waiting" {
                    ApprovalCard(session: session, pendingCall: session.waitingFor == "permission prompt" ? pendingCall : nil)
                } else {
                    Composer(sessionID: sessionID, isWorking: isWorking)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

private struct WorkingCapsule: View {
    let since: Date?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { context in
            Label {
                if let since {
                    Text("Working \(Duration.seconds(max(0, context.date.timeIntervalSince(since)).rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: .capsule)
    }
}

private struct ApprovalCard: View {
    let session: RemoteSession
    let pendingCall: ToolCall?

    @Environment(RemoteClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(session.waitingFor.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Needs you", systemImage: "exclamationmark.bubble.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)
            if let pendingCall {
                Text(pendingCall.use.detail ?? pendingCall.use.name ?? "Tool")
                    .font(.headline)
                if let target = pendingCall.use.command ?? pendingCall.use.filePath {
                    Text(verbatim: target)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            } else {
                Text("Claude is waiting for an answer in Berth.")
                    .font(.headline)
            }
            HStack(spacing: 8) {
                ForEach([("1", RemoteKey.digit1), ("2", .digit2), ("3", .digit3), ("Esc", .escape)], id: \.0) { title, key in
                    Button {
                        client.send(.key(sessionID: session.id, key: key, waitingFor: session.waitingFor, waitingSince: session.waitingSince))
                    } label: {
                        Text(title)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .disabled(client.state != .connected)
            Text("Picks an option of Claude’s question by number. Usually 1 is yes, 2 is yes and don’t ask again, 3 is no.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 24))
    }
}

private struct Composer: View {
    let sessionID: String
    let isWorking: Bool

    @Environment(RemoteClient.self) private var client
    @State private var draft = ""

    var body: some View {
        let isEmpty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        HStack(alignment: .bottom, spacing: 8) {
            TextField(isWorking ? "Queue for after this turn…" : "Message Claude", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.leading, 16)
                .padding(.vertical, 12)
            if isWorking, isEmpty {
                Button("Stop", systemImage: "stop.fill", action: stop)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .padding(6)
            } else {
                Button("Send", systemImage: "arrow.up", action: send)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .padding(6)
                    .disabled(isEmpty)
            }
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
        .disabled(client.state != .connected)
    }

    private func send() {
        client.send(.prompt(sessionID: sessionID, text: draft))
        draft = ""
    }

    private func stop() {
        client.send(.session(sessionID: sessionID, action: .interrupt))
    }
}
