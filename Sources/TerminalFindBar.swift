import GhosttyTerminal
import SwiftUI

struct TerminalSearch {
    let terminal: TerminalViewState
    var needle = ""
    var total: Int?
    var selected: Int?
    var focusRequests = 0
}

extension TerminalViewState: @retroactive TerminalSurfaceSearchDelegate {
    public func terminalDidStartSearch(needle: String?) {
        Store.shared.startTerminalSearch(in: self, needle: needle)
    }

    public func terminalDidEndSearch() {
        guard Store.shared.terminalSearch?.terminal === self else { return }
        Store.shared.terminalSearch = nil
    }

    public func terminalDidUpdateSearchTotal(_ total: Int?) {
        guard Store.shared.terminalSearch?.terminal === self else { return }
        Store.shared.terminalSearch?.total = total
    }

    public func terminalDidUpdateSearchSelected(_ selected: Int?) {
        guard Store.shared.terminalSearch?.terminal === self else { return }
        Store.shared.terminalSearch?.selected = selected
    }
}

struct TerminalFindBar: View {
    @Environment(Store.self) private var store
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        let needle = Binding(get: { store.terminalSearch?.needle ?? "" }, set: { store.terminalSearch?.needle = $0 })
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: needle, selection: $selection, prompt: Text("Find"))
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    store.focusedTerminal?.performBindingAction(press.modifiers.contains(.shift) ? "navigate_search:previous" : "navigate_search:next")
                    return .handled
                }
                .onExitCommand(perform: close)
            Text("9999 of 9999")
                .hidden()
                .overlay(alignment: .trailing) { Text(count) }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            HStack(spacing: 2) {
                Button("Previous Match", systemImage: "chevron.up") { store.focusedTerminal?.performBindingAction("navigate_search:previous") }
                    .help("Previous Match (⇧⌘G)")
                Button("Next Match", systemImage: "chevron.down") { store.focusedTerminal?.performBindingAction("navigate_search:next") }
                    .help("Next Match (⌘G)")
                Button("Close", systemImage: "xmark", action: close)
                    .help("Close (esc)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .onChange(of: store.terminalSearch?.focusRequests, initial: true) {
            isFocused = true
            selection = TextSelection(range: needle.wrappedValue.startIndex..<needle.wrappedValue.endIndex)
        }
    }

    private var count: String {
        guard let search = store.terminalSearch, !search.needle.isEmpty, let total = search.total else { return "" }
        if total == 0 { return "No results" }
        return search.selected.map { "\($0 + 1) of \(total)" } ?? "\(total) results"
    }

    private func close() {
        store.endTerminalSearch()
        store.focusedTerminal?.requestFocus()
    }
}
