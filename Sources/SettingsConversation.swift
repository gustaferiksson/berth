import SwiftUI

struct ConversationSettings: View {
    @AppStorage(GeneralSettings.conversationKey) private var isConversationEnabled = false
    @AppStorage(GeneralSettings.conversationViewKey) private var conversationView = "terminal"

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
        }
        .formStyle(.grouped)
        .frame(height: isConversationEnabled ? 290 : 230)
    }
}
