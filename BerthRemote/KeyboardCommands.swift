import SwiftUI

struct SessionListActions {
    let canStartSession: Bool
    let newSession: () -> Void
    let search: () -> Void
    let refresh: () -> Void
    let selectPrevious: () -> Void
    let selectNext: () -> Void
}

struct ComposerActions: Equatable {
    let canSend: Bool
    let canStop: Bool
    let send: () -> Void
    let stop: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.canSend == rhs.canSend && lhs.canStop == rhs.canStop
    }
}

extension FocusedValues {
    @Entry var sessionListActions: SessionListActions?
    @Entry var composerActions: ComposerActions?
}

struct RemoteCommands: Commands {
    @FocusedValue(\.sessionListActions) private var list
    @FocusedValue(\.composerActions) private var composer

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session", systemImage: "plus", action: { list?.newSession() })
                .keyboardShortcut("n")
                .disabled(list?.canStartSession != true)
        }
        CommandMenu("Session") {
            Button("Send Message", systemImage: "arrow.up", action: { composer?.send() })
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(composer?.canSend != true)
            Button("Stop", systemImage: "stop.fill", action: { composer?.stop() })
                .keyboardShortcut(".")
                .disabled(composer?.canStop != true)
            Divider()
            Button("Previous Session", systemImage: "chevron.up", action: { list?.selectPrevious() })
                .keyboardShortcut("[")
                .disabled(list == nil)
            Button("Next Session", systemImage: "chevron.down", action: { list?.selectNext() })
                .keyboardShortcut("]")
                .disabled(list == nil)
            Divider()
            Button("Search Sessions", systemImage: "magnifyingglass", action: { list?.search() })
                .keyboardShortcut("f")
                .disabled(list == nil)
            Button("Refresh Sessions", systemImage: "arrow.clockwise", action: { list?.refresh() })
                .keyboardShortcut("r")
                .disabled(list == nil)
        }
    }
}
