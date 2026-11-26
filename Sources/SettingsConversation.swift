import AppKit
import SwiftUI

struct ConversationSettings: View {
    @AppStorage(GeneralSettings.conversationKey) private var isConversationEnabled = false
    @AppStorage(GeneralSettings.conversationViewKey) private var conversationView = "terminal"
    @AppStorage(ConversationTypography.bodyFontKey) private var bodyFont = ConversationTypeset.standard.bodyFont
    @AppStorage(ConversationTypography.bodyFamilyKey) private var bodyFamily = ConversationTypeset.standard.bodyFamily
    @AppStorage(ConversationTypography.bodySizeKey) private var bodySize = ConversationTypeset.standard.bodySize
    @AppStorage(ConversationTypography.lineSpacingKey) private var lineSpacing = ConversationTypeset.standard.lineSpacing
    @AppStorage(ConversationTypography.widthKey) private var width = ConversationTypeset.standard.width

    @AppStorage(ConversationShellCompleter.enabledKey) private var completesShell = false
    private let tine = TineStatus.shared
    private let familyGroups = ConversationTypography.familyGroups

    var body: some View {
        Form {
            Section {
                Toggle("Conversation view", isOn: $isConversationEnabled)
                if isConversationEnabled {
                    Picker("New Claude tabs open in", selection: $conversationView) {
                        Text("Terminal").tag("terminal")
                        Text("Conversation").tag("conversation")
                    }
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("Experimental. The conversation view (⌥⌘J) shows a Claude session as a native transcript in place of the terminal. Claude keeps running in the terminal underneath, so switching back loses nothing.")
            }
            if isConversationEnabled {
                Section {
                    Toggle("Shell completions (tine)", isOn: $completesShell)
                        .disabled(!tine.isAvailable)
                } footer: {
                    Text(tine.isUnsupported ? "Needs tine 0.1.48" : tine.isAvailable ? "Suggests commands, flags and paths while you type after \"!\". Tab accepts and Esc hides the list." : "Install and open tine to turn this on.")
                }
                Section {
                    Picker("Style", selection: style) {
                        ForEach(ConversationStyle.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                        Text("Custom").tag(ConversationStyle?.none)
                    }
                    Picker("Font", selection: $bodyFont) {
                        Text("System").tag(ConversationBodyFont.system)
                        Text("Monospaced").tag(ConversationBodyFont.monospaced)
                        Text("Custom").tag(ConversationBodyFont.custom)
                    }
                    if bodyFont == .custom {
                        Picker("Family", selection: $bodyFamily) {
                            Text("Choose a font").tag("")
                            ForEach(familyGroups, id: \.title) { group in
                                Section(group.title) {
                                    ForEach(group.families, id: \.self) { Text($0).tag($0) }
                                }
                            }
                        }
                    }
                    LabeledContent("Size") {
                        Stepper("\(Int(size($bodySize).wrappedValue)) pt", value: size($bodySize), in: 11...20)
                    }
                    Picker("Line spacing", selection: $lineSpacing) {
                        Text("Compact").tag(ConversationLineSpacing.compact)
                        Text("Normal").tag(ConversationLineSpacing.normal)
                        Text("Comfortable").tag(ConversationLineSpacing.comfortable)
                        Text("Relaxed").tag(ConversationLineSpacing.relaxed)
                        Text("Spacious").tag(ConversationLineSpacing.spacious)
                    }
                    Picker("Message width", selection: $width) {
                        Text("Narrow").tag(ConversationWidth.narrow)
                        Text("Normal").tag(ConversationWidth.normal)
                        Text("Full").tag(ConversationWidth.full)
                    }
                } header: {
                    Text("Text")
                } footer: {
                    Text("Code blocks, inline code and shell lines use Review's font, size and colours (Settings > Review).")
                }
                Section {
                    Button("Reset Text Settings") { apply(.standard) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: isConversationEnabled ? (bodyFont == .custom ? 715 : 670) : 230)
    }

    private func size(_ stored: Binding<Double>) -> Binding<Double> {
        Binding(get: { stored.wrappedValue > 0 ? stored.wrappedValue : ConversationTypography.terminalSize.rounded() }, set: { stored.wrappedValue = $0 })
    }

    private var typeset: ConversationTypeset {
        ConversationTypeset(bodyFont: bodyFont, bodyFamily: bodyFamily, bodySize: bodySize, lineSpacing: lineSpacing, width: width)
    }

    private var style: Binding<ConversationStyle?> {
        Binding(
            get: {
                var current = typeset
                if current.bodyFont != .custom { current.bodyFamily = "" }

                return ConversationStyle.allCases.first { $0.typeset == current }
            },
            set: { style in
                guard let style else { return }

                apply(style.typeset)
            }
        )
    }

    private func apply(_ typeset: ConversationTypeset) {
        bodyFont = typeset.bodyFont
        bodyFamily = typeset.bodyFamily
        bodySize = typeset.bodySize
        lineSpacing = typeset.lineSpacing
        width = typeset.width
    }
}
