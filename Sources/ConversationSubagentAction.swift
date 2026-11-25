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
    @ViewBuilder let content: () -> Content

    @Environment(\.openAgentConversation) private var open

    var body: some View {
        if isAgent {
            Button {
                open(agentID, toolUseID)
            } label: {
                content()
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open agent conversation for \(title)")
            .help("Open agent conversation")
        } else {
            content()
        }
    }
}
