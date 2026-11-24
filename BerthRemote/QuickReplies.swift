import SwiftUI

struct QuickReply: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String

    static let defaults = ["Continue", "Commit and push", "Run the tests"].map { Self(text: $0) }
}

extension [QuickReply]: @retroactive RawRepresentable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8), let replies = try? JSONDecoder().decode([QuickReply].self, from: data) else { return nil }

        self = replies
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self), let json = String(data: data, encoding: .utf8) else { return "[]" }

        return json
    }
}

struct QuickSlashCommand: Identifiable {
    let name: String
    let symbol: String
    let summary: String
    var isDestructive = false

    var id: String { name }

    static let all = [
        Self(name: "/compact", symbol: "rectangle.compress.vertical", summary: "Summarize the conversation to free up context"),
        Self(name: "/context", symbol: "chart.pie", summary: "Show what fills the context window"),
        Self(name: "/cost", symbol: "dollarsign.circle", summary: "Show token usage and cost"),
        Self(name: "/review", symbol: "checklist", summary: "Review a pull request"),
        Self(name: "/clear", symbol: "trash", summary: "Start over with an empty conversation", isDestructive: true),
    ]
}

struct QuickRepliesEditor: View {
    @AppStorage("showsQuickReplies") private var showsReplies = true
    @AppStorage("quickReplies") private var replies = QuickReply.defaults
    @State private var newText = ""

    var body: some View {
        List {
            Section {
                Toggle("Show Quick Replies", isOn: $showsReplies)
            } footer: {
                Text("Turn off to remove replies from the composer’s + menu. Slash commands stay.")
            }
            Section {
                ForEach($replies) { $reply in
                    TextField("Reply", text: $reply.text)
                        .deleteDisabled(!showsReplies)
                        .moveDisabled(!showsReplies)
                }
                .onDelete { replies.remove(atOffsets: $0) }
                .onMove { replies.move(fromOffsets: $0, toOffset: $1) }
                HStack {
                    TextField("Add a reply", text: $newText)
                        .onSubmit(add)
                    Button("Add", systemImage: "plus.circle.fill", action: add)
                        .labelStyle(.iconOnly)
                        .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text("Tapping a reply in the composer’s + menu puts it in the message box. Slash commands are built in and send at once.")
            }
            .disabled(!showsReplies)
        }
        .navigationTitle("Quick Replies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton().disabled(!showsReplies) }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        replies.append(QuickReply(text: text))
        newText = ""
    }
}
