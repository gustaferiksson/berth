import AppKit
import SwiftUI

struct ConversationSettings: View {
    @AppStorage(GeneralSettings.conversationKey) private var isConversationEnabled = false
    @AppStorage(GeneralSettings.conversationViewKey) private var conversationView = "terminal"
    @AppStorage(ConversationTypography.bodyFontKey) private var bodyFont = ConversationBodyFont.monospaced
    @AppStorage(ConversationTypography.bodyFamilyKey) private var bodyFamily = ""
    @AppStorage(ConversationTypography.bodySizeKey) private var bodySize = 0.0
    @AppStorage(ConversationTypography.lineSpacingKey) private var lineSpacing = ConversationLineSpacing.normal
    @AppStorage(ConversationTypography.codeFamilyKey) private var codeFamily = ""
    @AppStorage(ConversationTypography.codeSizeKey) private var codeSize = 0.0
    @AppStorage(ConversationTypography.widthKey) private var width = ConversationWidth.normal

    private let families = NSFontManager.shared.availableFontFamilies

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
                Section("Text") {
                    Picker("Font", selection: $bodyFont) {
                        Text("System").tag(ConversationBodyFont.system)
                        Text("Monospaced").tag(ConversationBodyFont.monospaced)
                        Text("Custom").tag(ConversationBodyFont.custom)
                    }
                    if bodyFont == .custom {
                        Picker("Family", selection: $bodyFamily) {
                            Text("Choose a font").tag("")
                            ForEach(families, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    LabeledContent("Size") {
                        Stepper("\(Int(size($bodySize).wrappedValue)) pt", value: size($bodySize), in: 11...20)
                    }
                    Picker("Line spacing", selection: $lineSpacing) {
                        Text("Compact").tag(ConversationLineSpacing.compact)
                        Text("Normal").tag(ConversationLineSpacing.normal)
                        Text("Relaxed").tag(ConversationLineSpacing.relaxed)
                    }
                    Picker("Message width", selection: $width) {
                        Text("Narrow").tag(ConversationWidth.narrow)
                        Text("Normal").tag(ConversationWidth.normal)
                        Text("Full").tag(ConversationWidth.full)
                    }
                }
                Section {
                    Picker("Font", selection: $codeFamily) {
                        Text("Terminal font").tag("")
                        ForEach(families, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Size") {
                        Stepper("\(Int(size($codeSize).wrappedValue)) pt", value: size($codeSize), in: 9...20)
                    }
                } header: {
                    Text("Code")
                } footer: {
                    Text("Sizes start at the terminal font size. Code covers code blocks, inline code, shell lines and diffs.")
                }
                Section {
                    Button("Reset Text Settings", action: reset)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: isConversationEnabled ? (bodyFont == .custom ? 720 : 670) : 230)
    }

    private func size(_ stored: Binding<Double>) -> Binding<Double> {
        Binding(get: { stored.wrappedValue > 0 ? stored.wrappedValue : ConversationTypography.terminalSize.rounded() }, set: { stored.wrappedValue = $0 })
    }

    private func reset() {
        bodyFont = .monospaced
        bodyFamily = ""
        bodySize = 0
        lineSpacing = .normal
        codeFamily = ""
        codeSize = 0
        width = .normal
    }
}
