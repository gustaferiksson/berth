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
            .buttonStyle(PopoverRowButtonStyle(isSelectable: dismissesPopover))
            .focusEffectDisabled(dismissesPopover)
            .accessibilityLabel("Open agent conversation: \(title)")
            .help("Open agent conversation")
        } else {
            content()
        }
    }
}

struct PopoverRowHover: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(isHovering ? 0.08 : 0), in: .rect(cornerRadius: 8))
            .onHover { isHovering = $0 }
    }
}

private struct PopoverRowButtonStyle: ButtonStyle {
    let isSelectable: Bool

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isSelectable: isSelectable)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let isSelectable: Bool
        @State private var isHovering = false
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let opacity = configuration.isPressed ? 0.12 : isSelectable && (isHovering || isFocused) ? 0.08 : 0
            configuration.label
                .background(Color.primary.opacity(opacity), in: .rect(cornerRadius: 8))
                .onHover { isHovering = $0 }
        }
    }
}
