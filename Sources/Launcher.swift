import BerthCore
import SwiftUI

enum LauncherMode {
    case newSession, search
}

struct Launcher: View {
    private struct Folder: Hashable {
        let path: String
        let sessions: Int
        let lastActivity: Date?
    }

    private enum Field {
        case query, prompt
    }

    let mode: LauncherMode

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @State private var query = Snapshot.launcherQuery
    @State private var prompt = ""
    @State private var highlighted = 0
    @State private var folders: [Folder] = []
    @State private var hits: [SearchHit] = []
    @State private var searchedQuery = ""
    @State private var resultsHeight = 0.0
    @State private var isBrowsing = false
    @FocusState private var focus: Field?

    private static let visibleMatches = 6

    var body: some View {
        let matches = mode == .newSession ? matches : []
        let target = matches.indices.contains(highlighted) ? matches[highlighted] : nil
        let count = mode == .newSession ? matches.count : hits.count
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .newSession ? "chevron.right" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Query", text: $query, prompt: Text(mode == .newSession ? "Search folders or type a path" : "Search all sessions"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focus, equals: .query)
                    .onKeyPress(.downArrow) { move(by: 1, in: count) }
                    .onKeyPress(.upArrow) { move(by: -1, in: count) }
                    .onKeyPress(.tab) {
                        guard mode == .newSession else { return .ignored }
                        focus = .prompt
                        return .handled
                    }
                    .onSubmit { submit(target) }
                    .onChange(of: query) { highlighted = 0 }
                if mode == .newSession {
                    Button("Browse…") { isBrowsing = true }
                        .keyboardShortcut("o")
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .help("Choose a folder (⌘O)")
                }
            }
            .padding(16)
            Divider()
            if mode == .newSession {
                folderList(matches)
            } else {
                results
            }
            Divider()
            HStack(spacing: 16) {
                if mode == .newSession {
                    hint("↩", target.map { "Start in \(URL(filePath: $0.path).lastPathComponent)" } ?? "Start")
                    hint("⇥", "Prompt")
                    hint("↑↓", "Folder")
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
            focus = .query
            guard mode == .newSession else {
                store.updateSearchIndex()
                return
            }
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
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                TextField("First Prompt", text: $prompt, prompt: Text("First prompt (optional)"))
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .prompt)
                    .onKeyPress(.tab) {
                        focus = .query
                        return .handled
                    }
                    .onSubmit { submit(matches.indices.contains(highlighted) ? matches[highlighted] : nil) }
            }
            .padding(16)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        hitRow(hit, isHighlighted: index == highlighted)
                            .id(index)
                            .onTapGesture { open(hit) }
                    }
                    if hits.isEmpty {
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
                .background(.quinary, in: .rect(cornerRadius: 4))
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func move(by offset: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        highlighted = min(max(highlighted + offset, 0), count - 1)
        return .handled
    }

    private func submit(_ target: Folder?) {
        if mode == .search {
            if hits.indices.contains(highlighted) { open(hits[highlighted]) }
            return
        }
        if let target { start(in: target.path) }
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

    private func open(_ hit: SearchHit) {
        store.activate(.session(hit.id))
        store.launcherMode = nil
    }

    private func start(in path: String) {
        store.openClaude(cwd: path, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        store.launcherMode = nil
    }
}
