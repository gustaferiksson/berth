import SwiftUI

extension EnvironmentValues {
    @Entry var openAgentConversation = OpenAgentConversation { _, _ in }
}

struct OpenAgentConversation {
    let open: (String?, String?) -> Void

    func callAsFunction(_ agentID: String?, _ toolUseID: String?) {
        open(agentID, toolUseID)
    }
}

struct ConversationAgentButton<Content: View>: View {
    let isAgent: Bool
    let agentID: String?
    let toolUseID: String?
    let title: String
    var dismissesPopover = false
    @ViewBuilder let content: () -> Content

    @Environment(\.openAgentConversation) private var open
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if isAgent {
            Button {
                if dismissesPopover { dismiss() }
                open(agentID, toolUseID)
            } label: {
                content()
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open agent conversation: \(title)")
            .help("Open agent conversation")
        } else {
            content()
        }
    }
}
