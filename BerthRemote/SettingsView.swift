import SwiftUI

struct ConversationStyle: ViewModifier {
    @AppStorage("conversationFont") private var font = "system"
    @AppStorage("conversationTextSize") private var textSize = 0.0
    @AppStorage("conversationLineSpacing") private var lineSpacing = 2.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let sizes = DynamicTypeSize.allCases
        let index = (sizes.firstIndex(of: dynamicTypeSize) ?? 3) + Int(textSize)

        content
            .fontDesign(font == "rounded" ? .rounded : font == "serif" ? .serif : font == "monospaced" ? .monospaced : nil)
            .dynamicTypeSize(sizes[min(max(index, 0), sizes.count - 1)])
            .lineSpacing(lineSpacing)
    }
}

struct SettingsView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @AppStorage("conversationFont") private var font = "system"
    @AppStorage("conversationTextSize") private var textSize = 0.0
    @AppStorage("conversationCodeSize") private var codeSize = "medium"
    @AppStorage("conversationLineSpacing") private var lineSpacing = 2.0
    @AppStorage("colorScheme") private var colorScheme = "system"
    @AppStorage("remoteURL") private var address = ""

    private static let preview = Turn(
        id: "preview",
        prompt: RemoteEntry(id: "preview-prompt", kind: .prompt, text: "Why does the import fail on CI?"),
        parts: [.reply(RemoteEntry(id: "preview-reply", kind: .reply, text: "The parser reads dates in the runner’s time zone. Pin it to **Stockholm**:\n```swift\nformatter.timeZone = TimeZone(identifier: \"Europe/Stockholm\")\n```"))]
    )

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Address") {
                        Text(address)
                            .monospaced()
                    }
                    LabeledContent("Status", value: client.state == .connected ? "Connected" : client.state == .reconnecting ? "Reconnecting…" : "Not connected")
                    Button("Disconnect", role: .destructive, action: disconnect)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("To revoke this phone’s access, use Regenerate Token in Berth’s General settings on your Mac, then connect again with the new token.")
                }
                Section("Preview") {
                    TurnView(turn: Self.preview, isFinished: true, isWorking: false, turnStartedAt: nil, liveCall: nil)
                        .modifier(ConversationStyle())
                        .allowsHitTesting(false)
                        .padding(.vertical, 8)
                }
                Section {
                    Picker("Font", selection: $font) {
                        Text("System").tag("system")
                        Text("Rounded").tag("rounded")
                        Text("Serif").tag("serif")
                        Text("Monospaced").tag("monospaced")
                    }
                    LabeledContent {
                        Slider(value: $textSize, in: -2...3, step: 1) {
                            Text("Text Size")
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                                .accessibilityLabel("Smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                                .accessibilityLabel("Larger")
                        }
                    } label: {
                        Text("Text Size")
                    }
                    Picker("Code Size", selection: $codeSize) {
                        Text("Small").tag("small")
                        Text("Medium").tag("medium")
                        Text("Large").tag("large")
                    }
                    LabeledContent {
                        Slider(value: $lineSpacing, in: 0...8, step: 1) {
                            Text("Line Spacing")
                        }
                    } label: {
                        Text("Line Spacing")
                    }
                } header: {
                    Text("Conversation")
                } footer: {
                    Text("Text Size adds to the size set in the Settings app.")
                }
                Section {
                    NavigationLink("Quick Replies") { QuickRepliesEditor() }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $colorScheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func disconnect() {
        dismiss()
        client.disconnect()
    }
}
