import SwiftUI

struct SessionView: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @State private var draft = ""

    private var session: RemoteSession? {
        client.groups.lazy.flatMap(\.sessions).first { $0.id == sessionID }
    }

    var body: some View {
        let entries = client.entries[sessionID] ?? []
        let results = Dictionary(entries.filter { $0.kind == .toolResult }.compactMap { entry in entry.toolID.map { ($0, entry) } }) { _, last in last }
        let pending = session?.waitingFor == "permission prompt" ? entries.last { $0.kind == .toolUse && results[$0.toolID ?? ""] == nil } : nil

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries.filter { $0.kind != .toolResult }) { entry in
                        if entry.kind == .toolUse {
                            ToolCallView(call: entry, result: results[entry.toolID ?? ""])
                        } else {
                            Text(((try? AttributedString(markdown: entry.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(entry.text)).transformingAttributes(\.link) { $0.value = nil })
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(entry.kind == .prompt ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
                                .frame(maxWidth: .infinity, alignment: entry.kind == .prompt ? .trailing : .leading)
                                .padding(entry.kind == .prompt ? .leading : .trailing, 40)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: entries.count) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if session?.status == "waiting" {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(session?.waitingFor ?? "Claude needs you", systemImage: "exclamationmark.bubble.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                        if let pending {
                            Text(pending.command ?? pending.filePath ?? pending.text)
                                .font(.caption.monospaced())
                                .lineLimit(4)
                        }
                        HStack {
                            ForEach([("1", RemoteKey.digit1), ("2", .digit2), ("3", .digit3), ("Esc", .escape)], id: \.0) { label, key in
                                Button(label) { client.send(.key(sessionID: sessionID, key: key, waitingFor: session?.waitingFor, waitingSince: session?.waitingSince)) }
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(client.state != .connected)
                        Text("Picks an option of Claude’s question by number. Usually 1 is yes, 2 is yes and don’t ask again, 3 is no.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16))
                }
                if session?.isLocked == true {
                    Text("Running in another terminal, so read-only here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if session?.status != "waiting" {
                    HStack(alignment: .bottom) {
                        TextField("Message Claude", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
                        Button("Send", systemImage: "arrow.up.circle.fill") {
                            client.send(.prompt(sessionID: sessionID, text: draft))
                            draft = ""
                        }
                        .labelStyle(.iconOnly)
                        .font(.title)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || client.state != .connected)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task { client.subscribe(to: sessionID) }
        .alert("Berth", isPresented: Binding { client.notice != nil } set: { if !$0 { client.notice = nil } }) {
            Button("OK") {}
        } message: {
            Text(client.notice ?? "")
        }
    }
}

private struct ToolCallView: View {
    let call: RemoteEntry
    let result: RemoteEntry?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let command = call.command {
                    Text(command)
                        .font(.caption.monospaced())
                } else if call.oldText != nil || call.newText != nil {
                    if let oldText = call.oldText {
                        Text(oldText)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.red.opacity(0.15), in: .rect(cornerRadius: 6))
                    }
                    if let newText = call.newText {
                        Text(newText)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.green.opacity(0.15), in: .rect(cornerRadius: 6))
                    }
                } else {
                    Text(call.text)
                        .font(.caption.monospaced())
                }
                if let result {
                    Divider()
                    Text(result.text.isEmpty ? "(no output)" : result.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(result.isError ? .red : .secondary)
                        .lineLimit(12)
                }
            }
            .textSelection(.enabled)
            .padding(.top, 4)
        } label: {
            Label {
                Text("\(call.name ?? "Tool") \(Text(call.command ?? call.filePath.map { URL(filePath: $0).lastPathComponent } ?? "").foregroundStyle(.secondary))")
                    .font(.subheadline)
                    .lineLimit(1)
            } icon: {
                Image(systemName: result == nil ? "hourglass" : result?.isError == true ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(result?.isError == true ? .red : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 12))
    }
}
