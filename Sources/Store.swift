import Foundation
import GhosttyTerminal
import Observation

struct Tab: Identifiable {
    enum Kind: Equatable {
        case shell
        case claude(sessionID: String)
    }

    let id = UUID()
    let kind: Kind
    let cwd: String
    let terminal: TerminalViewState
}

@Observable
final class Store {
    var tabs: [Tab] = []
    var selectedTabID: Tab.ID?

    func openShell(cwd: String) {
        open(kind: .shell, cwd: cwd, command: nil)
    }

    private func open(kind: Tab.Kind, cwd: String, command: String?) {
        let terminal = TerminalViewState(controller: GhosttyConfig.controller)
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: cwd,
            command: command,
            waitAfterCommand: false
        )
        let tab = Tab(kind: kind, cwd: cwd, terminal: terminal)
        terminal.onClose = { [weak self] _ in self?.close(tab.id) }
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func close(_ id: Tab.ID) {
        tabs.removeAll { $0.id == id }
        if selectedTabID == id { selectedTabID = tabs.last?.id }
    }
}
