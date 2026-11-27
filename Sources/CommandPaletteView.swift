import BerthCore
import GhosttyTerminal
import SwiftUI

enum PaletteContext: String {
    case terminal, conversation, review, browser, session, files

    init(in store: Store) {
        let responder = NSApp.keyWindow?.firstResponder
        let item = store.sidebarCursor ?? store.selection
        let view = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil } ?? responder as? NSView
        if store.isReviewTextFocused || responder is ReviewTextView || store.isReviewPanelFocused {
            self = store.shownPane == .files ? .files : .review
        } else if store.isFilesPanelFocused {
            self = .files
        } else if store.shownPane == .browser, let view, sequence(first: view, next: \.superview).contains(where: { $0 is NSHostingView<PaneHost> }) {
            self = .browser
        } else if store.isSidebarListFocused || store.isSidebarFilterFocused, let item {
            switch item {
            case .session, .task: self = .session
            case let .tab(id): self = store.tabs.contains { $0.id == id && $0.kind == .claude } ? .session : .terminal
            }
        } else if responder is ComposerTextView || responder is ConversationNSTextView || store.isConversationTranscriptFocused {
            self = .conversation
        } else if let responder, store.focusedTerminal?.attachedPlatformView === responder {
            self = store.selectedShowsConversation ? .conversation : .terminal
        } else {
            self = switch store.shownPane {
            case .changes: .review
            case .files: .files
            case .browser: .browser
            case .terminal, .tasks, nil: store.selectedShowsConversation ? .conversation : store.focusedTerminal == nil && store.selection != nil ? .session : .terminal
            }
        }
    }
}

struct CommandPaletteView: View {
    @Environment(Store.self) private var store
    @State private var query: String
    @State private var highlighted = 0
    @State private var resultsHeight = 0.0
    @FocusState private var isQueryFocused: Bool

    init(query: String) {
        _query = State(initialValue: query)
    }

    var body: some View {
        let actions = AppAction.palette.filter { $0.isAvailable(in: store) }
        let byTitle = Dictionary(actions.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = CommandPalette.rank(query, items: actions.map { action in
            PaletteItem(id: action.title, section: action.contexts.contains(store.paletteContext) ? .context : .general, title: action.title(in: store), detail: action.keywords)
        })
        let selection = min(highlighted, max(rows.count - 1, 0))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: AppAction.commandPalette.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                TextField("Type a command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($isQueryFocused)
                    .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in move(by: 1, from: selection, count: rows.count) }
                    .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in move(by: -1, from: selection, count: rows.count) }
                    .onSubmit {
                        if rows.indices.contains(selection), let action = byTitle[rows[selection].id] { run(action) }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if rows.isEmpty {
                            LauncherMessage(symbol: "magnifyingglass", title: "No matching commands")
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if query.allSatisfy(\.isWhitespace), index == 0 || rows[index - 1].section != row.section {
                                LauncherSectionHeader(row.section == .context ? store.paletteContext.rawValue.capitalized : "General")
                                    .padding(.top, index == 0 ? 0 : 6)
                            }
                            if let action = byTitle[row.id] {
                                Button { run(action) } label: {
                                    LauncherRowFrame(symbol: .symbol(action.symbol), tint: .accentColor, title: row.title, isHighlighted: index == selection) {
                                        HStack(spacing: 10) {
                                            if let shortcut = action.shortcutLabel {
                                                Text(verbatim: shortcut)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                            }
                                            if index != selection {
                                                Color.clear.frame(width: 22, height: 20)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .id(index)
                            }
                        }
                    }
                    .padding(8)
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { resultsHeight = $0 }
                }
                .frame(height: min(max(resultsHeight, 64), 420))
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: selection) { proxy.scrollTo(selection) }
                .onChange(of: query) {
                    highlighted = 0
                    if !rows.isEmpty { proxy.scrollTo(0, anchor: .top) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                LauncherKeyHint("↩", "Run")
                LauncherKeyHint("↑↓", "Select")
                Spacer(minLength: 0)
                LauncherKeyHint("esc", "Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: 680)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 24)
        .onExitCommand { store.launcherMode = nil }
        .onAppear {
            store.launcherQuery = ""
            if Snapshot.output == nil { isQueryFocused = true }
        }
    }

    private func move(by offset: Int, from selection: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }

        highlighted = min(max(selection + offset, 0), count - 1)
        return .handled
    }

    private func run(_ action: AppAction) {
        guard action.isAvailable(in: store) else { return }

        action.perform(on: store)
        if store.launcherMode == .palette { store.launcherMode = nil }
    }
}
