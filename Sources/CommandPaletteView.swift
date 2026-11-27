import BerthCore
import GhosttyTerminal
import SwiftUI

enum PaletteContext: String {
    case terminal, conversation, review, browser, session, files

    init(in store: Store) {
        let responder = NSApp.keyWindow?.firstResponder
        let item = store.sidebarCursor ?? store.selection
        let view = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil } ?? responder as? NSView
        let selectedTabShowsConversation = store.selectedTabID == store.mainTabID && store.selectedShowsConversation
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
            self = selectedTabShowsConversation ? .conversation : .terminal
        } else {
            self = switch store.shownPane {
            case .changes: .review
            case .files: .files
            case .browser: .browser
            case .terminal, .tasks, nil: selectedTabShowsConversation ? .conversation : store.focusedTerminal == nil && store.selection != nil ? .session : .terminal
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
        let isBlank = query.allSatisfy(\.isWhitespace)
        let startsSection = { (index: Int) in isBlank && (index == 0 || rows[index - 1].section != rows[index].section) }
        let selection = min(highlighted, max(rows.count - 1, 0))
        let selectedRow = rows.indices.contains(selection) ? rows[selection] : nil
        let scopeGlyph = LauncherGlyph.symbol(AppAction.commandPalette.symbol)
        LauncherPanel(searchGlyph: scopeGlyph) {
            TextField("Type a command", text: $query)
                .focused($isQueryFocused)
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in move(by: 1, from: selection, count: rows.count) }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in move(by: -1, from: selection, count: rows.count) }
                .onSubmit {
                    if let selectedRow, let action = byTitle[selectedRow.id] { run(action) }
                }
        } results: {
            Divider()
            ScrollViewReader { proxy in
                LauncherResultList(contentHeight: $resultsHeight, maxHeight: 440) {
                    if rows.isEmpty {
                        LauncherMessage(symbol: "magnifyingglass", title: "No matching commands")
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if startsSection(index) {
                            LauncherSectionHeader(row.section == .context ? store.paletteContext.rawValue.capitalized : "General")
                                .padding(.top, index == 0 ? 0 : 6)
                                .id("header\(index)")
                        }
                        if let action = byTitle[row.id] {
                            Button { run(action) } label: {
                                LauncherRowFrame(symbol: .symbol(action.symbol), tint: .secondary, title: row.title, isHighlighted: index == selection, minHeight: 36) {
                                    if let shortcut = action.shortcutLabel {
                                        Text(verbatim: shortcut)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .id(index)
                        }
                    }
                }
                .onChange(of: selection) {
                    proxy.scrollToLauncherRow(selection, startsSection: !rows.isEmpty && startsSection(selection))
                    #if DEBUG
                    store.probeLauncherSelection = selection
                    #endif
                }
                .onChange(of: query) {
                    highlighted = 0
                    if isBlank { proxy.scrollTo("launcherResultsTop", anchor: .top) } else if !rows.isEmpty { proxy.scrollTo(0, anchor: .top) }
                }
            }
        } footer: {
            LauncherCommandFooter(scopeGlyph: scopeGlyph, title: selectedRow?.title, primaryTitle: "Run")
        }
        .onExitCommand { store.launcherMode = nil }
        .onAppear {
            store.launcherQuery = ""
            if Snapshot.output == nil || Snapshot.launcherKeys != nil { isQueryFocused = true }
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
