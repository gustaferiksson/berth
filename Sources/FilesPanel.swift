import AppKit
import BerthCore
import SwiftUI

struct FilesPanel: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let session = store.sessionTab, let review = store.primaryReviewModel {
            FilesList(files: store.filesModel(for: session), review: review)
                .id(ObjectIdentifier(review))
        } else {
            ContentUnavailableView("Select a Claude Session", systemImage: "folder", description: Text("Its files show here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FilesList: View {
    let files: FilesModel
    let review: ReviewModel
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme
    @State private var isSectionExpanded = true
    @FocusState private var isFocused: Bool

    var body: some View {
        let root = review.changes?.root ?? review.folder
        let statuses = Dictionary(review.changes?.uncommitted.map { ($0.path, $0.status) } ?? [], uniquingKeysWith: { first, _ in first })
        let changedFolders = Set(statuses.keys.flatMap { path in path.split(separator: "/").dropLast().reduce(into: [String]()) { $0.append(($0.last.map { $0 + "/" } ?? "") + $1) } })
        let rows = files.rows
        VStack(spacing: 0) {
            filterBar
            List {
                SidebarSection(title: (root as NSString).lastPathComponent, help: "Files in the session’s folder", isExpanded: $isSectionExpanded) {
                    if files.filter.isEmpty {
                        ForEach(rows) { row in
                            FilesRow(row: row, files: files, review: review, root: root, status: statuses[row.entry.path], hasChanges: changedFolders.contains(row.entry.path))
                        }
                    } else {
                        ForEach(files.matches, id: \.self) { path in
                            FilesRow(row: FileRow(entry: FileEntry(path: path, name: (path as NSString).lastPathComponent, isFolder: false, isIgnored: false), depth: 0), files: files, review: review, root: root, status: statuses[path], hasChanges: false, showsFolder: true)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .focusable()
            .focused($isFocused)
            .onKeyPress(.upArrow) { step(-1, rows: rows) }
            .onKeyPress(.downArrow) { step(1, rows: rows) }
            .onKeyPress(.rightArrow) { fold(expanding: true, rows: rows) }
            .onKeyPress(.leftArrow) { fold(expanding: false, rows: rows) }
            .onKeyPress(.return) { activate(rows: rows) }
        }
        .task(id: root) {
            files.attach(root: root)
            if review.changes == nil { await review.load() }
            guard let selected = files.selected, review.selectedDocument?.path != selected else { return }

            store.openFile(selected, in: files, review: review)
        }
        .task(id: [review.selectedDocument?.path, review.changes?.root]) { await review.loadSelectedContents() }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondary)
                .accessibilityHidden(true)
            TextField("Filter Files", text: Bindable(files).filter)
                .textFieldStyle(.plain)
            if !files.filter.isEmpty {
                Button("Clear Filter", systemImage: "xmark.circle.fill") { files.filter = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.secondary)
            }
            Toggle("Show Ignored Files", systemImage: files.showsIgnored ? "eye" : "eye.slash", isOn: Bindable(files).showsIgnored)
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(files.showsIgnored ? Color.accentColor : theme.secondary)
                .help("Show Ignored Files")
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.foreground.opacity(0.06), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func step(_ offset: Int, rows: [FileRow]) -> KeyPress.Result {
        let paths = files.filter.isEmpty ? rows.map(\.id) : files.matches
        guard !paths.isEmpty else { return .ignored }

        let current = files.cursor.flatMap { paths.firstIndex(of: $0) }
        let next = paths[min(max((current ?? (offset > 0 ? -1 : paths.count)) + offset, 0), paths.count - 1)]
        files.cursor = next
        if rows.first(where: { $0.id == next })?.entry.isFolder != true { store.openFile(next, in: files, review: review) }
        return .handled
    }

    private func fold(expanding: Bool, rows: [FileRow]) -> KeyPress.Result {
        guard files.filter.isEmpty, let cursor = files.cursor, let row = rows.first(where: { $0.id == cursor }) else { return .ignored }

        if row.entry.isFolder, files.expanded.contains(cursor) != expanding {
            files.toggle(cursor)
        } else if !expanding, row.depth > 0 {
            files.cursor = (cursor as NSString).deletingLastPathComponent
        }
        return .handled
    }

    private func activate(rows: [FileRow]) -> KeyPress.Result {
        guard let cursor = files.cursor else { return .ignored }

        if rows.first(where: { $0.id == cursor })?.entry.isFolder == true {
            files.toggle(cursor)
        } else {
            store.openFile(cursor, in: files, review: review)
            review.focusesEditor = true
        }
        return .handled
    }
}

private struct FilesRow: View {
    let row: FileRow
    let files: FilesModel
    let review: ReviewModel
    let root: String
    let status: ReviewFile.Status?
    let hasChanges: Bool
    var showsFolder = false
    @State private var isHovering = false
    @Environment(Store.self) private var store
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        let entry = row.entry
        let isSelected = !entry.isFolder && files.selected == entry.path
        let isCursor = files.cursor == entry.path
        let isExpanded = files.expanded.contains(entry.path)
        let absolute = root + "/" + entry.path
        HStack(spacing: 6) {
            Image(systemName: entry.isFolder ? (isExpanded ? "chevron.down" : "chevron.right") : "doc")
                .font(.system(size: entry.isFolder ? 10 : 12, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(entry.name)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(.regular)
            if showsFolder, case let folder = (entry.path as NSString).deletingLastPathComponent, !folder.isEmpty {
                Text(folder)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if let status {
                Text(status.rawValue)
                    .font(.caption2.weight(.medium).monospaced())
                    .foregroundStyle(status.color(in: theme))
                    .accessibilityLabel("Changed")
            } else if hasChanges {
                Circle()
                    .fill(theme.secondary)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Contains changes")
            }
        }
        .font(.subheadline)
        .foregroundStyle(entry.isIgnored ? theme.secondary : theme.foreground)
        .padding(.vertical, 6.5)
        .reviewRow(leading: Double(row.depth) * ReviewInset.tree)
        .contentShape(.rect)
        .onTapGesture {
            files.cursor = entry.path
            if entry.isFolder { files.toggle(entry.path) } else { store.openFile(entry.path, in: files, review: review) }
        }
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .listRowBackground(RowFill(opacity: isSelected ? 0.18 : isCursor ? 0.1 : isHovering ? 0.06 : 0, color: isSelected ? .accentColor : .primary, cornerRadius: 6, verticalInset: 1))
        .help(entry.path)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: absolute)]) }
            Button("Open in Default App") { NSWorkspace.shared.open(URL(filePath: absolute)) }
            Divider()
            Button("Copy Path") { copy(absolute) }
            Button("Copy Relative Path") { copy(entry.path) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
