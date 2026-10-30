import BerthCore
import SwiftUI

enum LauncherMode {
    case newSession, search, palette
}

struct Launcher: View {
    private struct Folder: Hashable {
        let path: String
        let sessions: Int
        let lastActivity: Date?
    }

    private enum PaletteTarget {
        case item(SidebarItem)
        case action(AppAction)
    }

    private struct PaletteRow {
        let item: PaletteItem
        let target: PaletteTarget
        let symbol: String
        let trailing: String
    }

    let mode: LauncherMode

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @State private var query = ""
    @State private var highlighted = 0
    @State private var folders: [Folder] = []
    @State private var hits: [SearchHit] = []
    @State private var searchedQuery = ""
    @State private var resultsHeight = 0.0
    @State private var isBrowsing = false
    @FocusState private var isQueryFocused: Bool

    private static let visibleMatches = 6

    var body: some View {
        let matches = mode == .newSession ? matches : []
        let rows = mode == .palette ? paletteRows : []
        let target = matches.indices.contains(highlighted) ? matches[highlighted] : nil
        let row = rows.indices.contains(highlighted) ? rows[highlighted] : nil
        let count = mode == .newSession ? matches.count : mode == .palette ? rows.count : hits.count
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .newSession ? "chevron.right" : mode == .palette ? "command" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Query", text: $query, prompt: Text(mode == .newSession ? "Search folders or type a path" : mode == .palette ? "Type a command or session" : "Search all sessions"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isQueryFocused)
                    .onKeyPress(.downArrow) { move(by: 1, in: count) }
                    .onKeyPress(.upArrow) { move(by: -1, in: count) }
                    .onSubmit(submit)
                    .onChange(of: query) { highlighted = 0 }
                if mode == .newSession {
                    Button { isBrowsing = true } label: {
                        Text("Browse…")
                            .font(.subheadline)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(theme.foreground.opacity(0.1), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("o")
                    .help("Choose a folder (⌘O)")
                }
            }
            .padding(16)
            Divider()
            if mode == .newSession {
                folderList(matches)
            } else {
                results(rows)
            }
            Divider()
            HStack(spacing: 16) {
                if mode == .newSession {
                    hint("↩", target.map { "Start in \(URL(filePath: $0.path).lastPathComponent)" } ?? "Start")
                    hint("↑↓", "Folder")
                } else if mode == .palette {
                    hint("↩", row.map { if case .action = $0.target { "Run" } else if $0.item.section == .openTab { "Switch To" } else { "Resume" } } ?? "Run")
                    hint("↑↓", "Select")
                } else {
                    hint("↩", "Open")
                    hint("↑↓", "Session")
                }
                Spacer()
                if mode == .search, let indexing = store.searchIndexing {
                    Text("Indexing \(indexing.done)/\(indexing.total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                hint("esc", mode == .newSession ? "Cancel" : "Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: mode == .newSession ? 560 : 640)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 24)
        .onExitCommand { store.launcherMode = nil }
        .onAppear {
            query = store.launcherQuery
            store.launcherQuery = ""
            isQueryFocused = true
            if mode == .search { store.updateSearchIndex() }
            guard mode == .newSession else { return }
            let known = store.knownFolders
            let current = store.currentCwd
            let promoted = current == FileManager.default.homeDirectoryForCurrentUser.path ? [] : [known.first { $0.path == current } ?? (path: current, sessions: 0, lastActivity: .distantPast)]
            folders = (promoted + known.filter { $0.path != promoted.first?.path })
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { Folder(path: $0.path, sessions: $0.sessions, lastActivity: $0.sessions > 0 ? $0.lastActivity : nil) }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            await search()
        }
        .onChange(of: store.searchIndexVersion) { Task { await search() } }
        .fileImporter(isPresented: $isBrowsing, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            start(in: url.path)
        }
    }

    private func folderList(_ matches: [Folder]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element) { index, folder in
                folderRow(folder, isHighlighted: index == highlighted)
                    .onTapGesture { start(in: folder.path) }
            }
            if matches.isEmpty {
                Text(folders.isEmpty ? "No session folders yet. Type a path or browse." : "No matching folders")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(8)
    }

    private func results(_ rows: [PaletteRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if mode == .palette {
                        ForEach(Array(rows.enumerated()), id: \.element.item) { index, row in
                            if query.allSatisfy(\.isWhitespace), index == 0 || rows[index - 1].item.section != row.item.section {
                                Text(row.item.section == .openTab ? "Sessions" : "Actions")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 4)
                            }
                            paletteRow(row, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { run(row.target) }
                        }
                    } else {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            hitRow(hit, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { open(hit) }
                        }
                    }
                    if mode == .search, hits.isEmpty {
                        Text(query.allSatisfy(\.isWhitespace) ? "Type to search every session’s prompts and replies" : store.searchIndexing == nil && searchedQuery == query ? "No matching sessions" : "Searching…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                }
                .padding(8)
                .onGeometryChange(for: Double.self) { $0.size.height } action: { resultsHeight = $0 }
            }
            .frame(height: min(max(resultsHeight, 64), 480))
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: highlighted) { proxy.scrollTo(highlighted) }
        }
    }

    private var matches: [Folder] {
        let typed = (query.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let ranked = folders.enumerated()
            .compactMap { index, folder in FuzzyMatch.score(typed, name: URL(filePath: folder.path).lastPathComponent, path: folder.path).map { (index, $0, folder) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map(\.2)
        var isDirectory: ObjCBool = false
        let isNewPath = typed.hasPrefix("/") && FileManager.default.fileExists(atPath: typed, isDirectory: &isDirectory) && isDirectory.boolValue
        let path = URL(filePath: typed).standardizedFileURL.path
        let typedFolder = isNewPath && !folders.contains { $0.path == path } ? [Folder(path: path, sessions: 0, lastActivity: nil)] : []
        return Array((typedFolder + ranked).prefix(Self.visibleMatches))
    }

    private func folderRow(_ folder: Folder, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(filePath: folder.path).lastPathComponent)
                    .fontWeight(.medium)
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            (folder.lastActivity.map { Text("^[\(folder.sessions) session](inflect: true) · \(age(since: $0))") } ?? Text("New folder"))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private var paletteRows: [PaletteRow] {
        let openTabs = store.sidebarOrderedTabs.map { tab in
            PaletteRow(
                item: PaletteItem(id: tab.id.uuidString, section: .openTab, title: tab.title(terminalTitle: tab.terminal.title, sessionTitle: store.sessionTitle(of: tab)), detail: tab.cwd),
                target: .item(.tab(tab.id)),
                symbol: tab.id == store.selectedTabID ? "checkmark" : "terminal",
                trailing: URL(filePath: tab.cwd).lastPathComponent
            )
        }
        let actions = AppAction.palette.filter { $0.isAvailable(in: store) }.map { action in
            PaletteRow(
                item: PaletteItem(id: action.title, section: .action, title: action.title, detail: action.keywords),
                target: .action(action),
                symbol: action.symbol,
                trailing: action.shortcut.map { shortcut in
                    [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined() + String(shortcut.key.character).uppercased()
                } ?? ""
            )
        }
        let open = Set(store.tabs.compactMap(\.sessionID))
        let recents = store.activeSessions.filter { !open.contains($0.id) }.sorted { $0.lastActivity > $1.lastActivity }.map { session in
            PaletteRow(
                item: PaletteItem(id: session.id, section: .recentSession, title: session.title, detail: session.cwd),
                target: .item(.session(session.id)),
                symbol: "clock.arrow.circlepath",
                trailing: "\(URL(filePath: session.cwd).lastPathComponent) · \(age(since: session.lastActivity))"
            )
        }
        let all = openTabs + actions + recents
        let byID = Dictionary(all.map { ($0.item.id, $0) }) { first, _ in first }
        let ranked = CommandPalette.rank(query, items: all.map(\.item), limit: 12).compactMap { byID[$0.id] }
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let search = actions.first(where: { $0.item.id == AppAction.searchSessions.title }) else { return ranked }
        let searchRow = PaletteRow(item: PaletteItem(id: search.item.id, section: .action, title: "Search Sessions for “\(typed)”", detail: ""), target: search.target, symbol: search.symbol, trailing: search.trailing)
        return ranked.map { $0.item.id == searchRow.item.id ? searchRow : $0 } + (ranked.contains { $0.item.id == searchRow.item.id } ? [] : [searchRow])
    }

    private func paletteRow(_ row: PaletteRow, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(row.item.title)
            Spacer(minLength: 8)
            Text(row.trailing)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func hitRow(_ hit: SearchHit, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(hit.session.title)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text("\(URL(filePath: hit.session.cwd).lastPathComponent) · \(age(since: hit.session.lastActivity))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            ForEach(hit.snippets, id: \.self) { snippet in
                Text(snippet.highlights.reduce(into: AttributedString(snippet.text)) { text, range in
                    guard let range = Range(range, in: text) else { return }
                    text[range].foregroundColor = theme.foreground
                    text[range].font = .caption.weight(.semibold)
                })
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.foreground.opacity(isHighlighted ? 0.1 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced())
                .padding(.horizontal, 4)
                .frame(minWidth: 20, minHeight: 16)
                .background(theme.foreground.opacity(0.1), in: .rect(cornerRadius: 4))
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func move(by offset: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = min(max(highlighted + offset, 0), count - 1)
        return .handled
    }

    private func submit() {
        if mode == .search {
            if hits.indices.contains(highlighted) { open(hits[highlighted]) }
            return
        }
        if mode == .palette {
            let rows = paletteRows
            if rows.indices.contains(highlighted) { run(rows[highlighted].target) }
            return
        }
        let matches = matches
        if matches.indices.contains(highlighted) { start(in: matches[highlighted].path) }
    }

    private func search() async {
        guard mode == .search else { return }
        let query = query
        let index = store.searchIndex
        let version = store.searchIndexVersion
        let sessions = store.activeSessions + store.archivedSessions
        let found = await Task.detached { index.search(query, in: sessions) }.value
        guard query == self.query, version == store.searchIndexVersion else { return }
        hits = found
        searchedQuery = query
        highlighted = min(highlighted, max(found.count - 1, 0))
    }

    private func run(_ target: PaletteTarget) {
        switch target {
        case let .item(item):
            store.activate(item)
            store.launcherMode = nil
        case .action(.searchSessions):
            store.launcherQuery = query.trimmingCharacters(in: .whitespaces)
            store.launcherMode = .search
        case let .action(action):
            action.perform(on: store)
            if store.launcherMode == .palette { store.launcherMode = nil }
        }
    }

    private func open(_ hit: SearchHit) {
        store.activate(.session(hit.id))
        store.launcherMode = nil
    }

    private func start(in path: String) {
        store.openClaude(cwd: path)
        store.launcherMode = nil
    }
}
