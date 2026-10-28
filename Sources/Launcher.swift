import BerthCore
import SwiftUI

struct Launcher: View {
    private struct Folder: Hashable {
        let path: String
        let sessions: Int
        let lastActivity: Date?
    }

    private enum Field {
        case query, prompt
    }

    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @State private var query = Snapshot.launcherQuery
    @State private var prompt = ""
    @State private var highlighted = 0
    @State private var folders: [Folder] = []
    @State private var isBrowsing = false
    @FocusState private var focus: Field?

    private static let visibleMatches = 6

    var body: some View {
        let matches = matches
        let target = matches.indices.contains(highlighted) ? matches[highlighted] : nil
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                TextField("Folder", text: $query, prompt: Text("Search folders or type a path"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focus, equals: .query)
                    .onKeyPress(.downArrow) { move(by: 1, in: matches) }
                    .onKeyPress(.upArrow) { move(by: -1, in: matches) }
                    .onKeyPress(.tab) {
                        focus = .prompt
                        return .handled
                    }
                    .onSubmit { if let target { start(in: target.path) } }
                    .onChange(of: query) { highlighted = 0 }
                Button("Browse…") { isBrowsing = true }
                    .keyboardShortcut("o")
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Choose a folder (⌘O)")
            }
            .padding(16)
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element) { index, folder in
                    row(folder, isHighlighted: index == highlighted)
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
                    .onSubmit { if let target { start(in: target.path) } }
            }
            .padding(16)
            Divider()
            HStack(spacing: 16) {
                hint("↩", target.map { "Start in \(URL(filePath: $0.path).lastPathComponent)" } ?? "Start")
                hint("⇥", "Prompt")
                hint("↑↓", "Folder")
                Spacer()
                hint("esc", "Cancel")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal, 24)
        .onExitCommand { store.isLauncherPresented = false }
        .onAppear {
            let known = store.knownFolders
            let current = store.currentCwd
            let promoted = current == FileManager.default.homeDirectoryForCurrentUser.path ? [] : [known.first { $0.path == current } ?? (path: current, sessions: 0, lastActivity: .distantPast)]
            folders = (promoted + known.filter { $0.path != promoted.first?.path })
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { Folder(path: $0.path, sessions: $0.sessions, lastActivity: $0.sessions > 0 ? $0.lastActivity : nil) }
            focus = .query
        }
        .fileImporter(isPresented: $isBrowsing, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            start(in: url.path)
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

    private func row(_ folder: Folder, isHighlighted: Bool) -> some View {
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

    private func move(by offset: Int, in matches: [Folder]) -> KeyPress.Result {
        guard !matches.isEmpty else { return .ignored }
        highlighted = min(max(highlighted + offset, 0), matches.count - 1)
        return .handled
    }

    private func start(in path: String) {
        store.openClaude(cwd: path, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        store.isLauncherPresented = false
    }
}
