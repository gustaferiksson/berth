import SwiftUI

struct ChangesSheet: View {
    let sessionID: String

    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var path: [RemoteClient.ChangeKey] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                switch client.changes[sessionID] {
                case let .loaded(changes):
                    ChangesContent(sessionID: sessionID, changes: changes)

                case .failed:
                    Section {
                        ContentUnavailableView {
                            Label("Couldn’t Load Changes", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Berth couldn’t read this session’s folder. It may not be a Git repository.")
                        } actions: {
                            Button("Try Again") { client.loadChanges(of: sessionID) }
                        }
                    }

                case nil:
                    Section {
                        ProgressView("Loading")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: RemoteClient.ChangeKey.self) { ChangeDiffView(key: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .task(id: client.state) {
                guard client.state == .connected else { return }

                client.loadChanges(of: sessionID)
            }
        }
        .presentationDetents([.large])
    }
}

private struct ChangesContent: View {
    let sessionID: String
    let changes: RemoteChanges

    var body: some View {
        if changes.uncommitted.isEmpty, changes.committed.isEmpty {
            ContentUnavailableView {
                Label("No Changes", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing differs from the base on \(Text(changes.branch).monospaced()).")
            }
        }
        if !changes.uncommitted.isEmpty {
            Section {
                ForEach(changes.uncommitted) { ChangedFileRow(sessionID: sessionID, file: $0, isCommitted: false) }
            } header: {
                Text("Uncommitted")
            }
        }
        if !changes.committed.isEmpty {
            Section {
                ForEach(changes.committed) { ChangedFileRow(sessionID: sessionID, file: $0, isCommitted: true) }
            } header: {
                Text("Committed\(changes.base.map { " against \($0)" } ?? "")")
            } footer: {
                if changes.isTruncated {
                    Text("Showing the first \(RemoteChangesFeature.maxFiles) files of each list.")
                }
            }
        } else if changes.isTruncated {
            Text("Showing the first \(RemoteChangesFeature.maxFiles) files of each list.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ChangedFileRow: View {
    let sessionID: String
    let file: RemoteChangedFile
    let isCommitted: Bool

    var body: some View {
        let url = URL(filePath: file.path)
        let folder = url.deletingLastPathComponent().relativePath
        let oldURL = file.oldPath.map { URL(filePath: $0) }
        let oldName = oldURL?.lastPathComponent
        let name = oldName.flatMap { $0 == url.lastPathComponent ? nil : "\($0) → \(url.lastPathComponent)" } ?? url.lastPathComponent
        let oldFolder = oldURL?.deletingLastPathComponent().relativePath
        let folderTitle = oldFolder.flatMap { $0 == folder ? nil : "\($0) → \(folder)" } ?? folder
        NavigationLink(value: RemoteClient.ChangeKey(sessionID: sessionID, path: file.path, isCommitted: isCommitted)) {
            HStack(spacing: 12) {
                Image(systemName: ChangeStatus.symbol(file.status))
                    .foregroundStyle(ChangeStatus.color(file.status))
                    .accessibilityLabel(ChangeStatus.title(file.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .fontWeight(.medium)
                        .monospaced()
                        .lineLimit(2)
                    if folderTitle != "." {
                        Text(folderTitle)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                if let additions = file.additions, let deletions = file.deletions {
                    Text("\(Text("+\(additions.formatted())").foregroundStyle(.green)) \(Text("−\(deletions.formatted())").foregroundStyle(.red))")
                        .font(.footnote)
                        .monospacedDigit()
                        .accessibilityLabel("\(additions) added, \(deletions) removed")
                }
            }
        }
    }
}

enum ChangeStatus {
    static func symbol(_ status: String) -> String {
        status == "A" ? "plus.circle.fill" : status == "D" ? "minus.circle.fill" : status == "R" ? "arrow.right.circle.fill" : "pencil.circle.fill"
    }

    static func color(_ status: String) -> Color {
        status == "A" ? .green : status == "D" ? .red : status == "R" ? .blue : .orange
    }

    static func title(_ status: String) -> String {
        status == "A" ? "Added" : status == "D" ? "Deleted" : status == "R" ? "Renamed" : "Modified"
    }
}

private struct ChangeDiffView: View {
    let key: RemoteClient.ChangeKey

    @Environment(RemoteClient.self) private var client

    var body: some View {
        let url = URL(filePath: key.path)
        let folder = url.deletingLastPathComponent().relativePath
        Group {
            switch client.diffs[key] {
            case let .loaded(diff) where diff.isBinary:
                ContentUnavailableView("Binary File", systemImage: "doc", description: Text("Berth can’t show a diff for binary files."))

            case let .loaded(diff) where diff.lines.isEmpty:
                ContentUnavailableView(diff.isTruncated ? "Truncated" : "No Changes to Show", systemImage: diff.isTruncated ? "scissors" : "checkmark.circle", description: Text(diff.isTruncated ? "This file is too large to show here." : "The file’s contents are the same."))

            case let .loaded(diff):
                DiffLines(diff: diff, language: key.path)

            case .failed:
                ContentUnavailableView {
                    Label("Couldn’t Load Diff", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Try Again") { client.loadDiff(key) }
                }

            case nil:
                ProgressView("Loading")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .monospaced()
                    if folder != "." {
                        Text(folder)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
        }
        .task(id: client.state) {
            guard client.state == .connected else { return }

            client.loadDiff(key)
        }
    }
}

private struct DiffLines: View {
    let diff: RemoteFileDiff
    let language: String

    @State private var viewportWidth: CGFloat = 0
    @State private var highlighted: [AttributedString] = []

    var body: some View {
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        let character = ("M" as NSString).size(withAttributes: [.font: font]).width
        let digits = diff.lines.compactMap { max($0.old ?? 0, $0.new ?? 0) }.max().map { String($0).count } ?? 1
        let gutter = character * CGFloat(digits) + 8
        let longest = diff.lines.map { $0.text.replacing("\t", with: "    ").count }.max() ?? 0
        let width = max(viewportWidth, gutter * 2 + character * CGFloat(longest + 1) + 32)

        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.lines.indices, id: \.self) { index in
                    DiffRow(line: diff.lines[index], highlighted: highlighted.indices.contains(index) ? highlighted[index] : nil, gutter: gutter, width: width)
                }
                if diff.isTruncated {
                    Text("Truncated")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .defaultScrollAnchor(.topLeading)
        .task(id: diff) {
            let rows = diff.lines.map { (old: $0.kind == .removed || $0.kind == .context, new: $0.kind == .added || $0.kind == .context, text: $0.text.replacing("\t", with: "    ")) }
            highlighted = await CodeHighlighting.diffLines(rows, language: language)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, width in viewportWidth = width }
        .font(.system(.footnote, design: .monospaced))
    }
}

private struct DiffRow: View {
    let line: RemoteDiffLine
    let highlighted: AttributedString?
    let gutter: CGFloat
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if line.kind == .hunk {
                Text(line.text)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            } else {
                Text(line.old.map(String.init) ?? "")
                    .frame(width: gutter, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Text(line.new.map(String.init) ?? "")
                    .frame(width: gutter, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                Text("\(Text(verbatim: marker))\(Text(highlighted ?? AttributedString(line.text.replacing("\t", with: "    "))))")
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 1)
        .frame(width: width, alignment: .leading)
        .background(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var marker: String {
        line.kind == .added ? "+" : line.kind == .removed ? "-" : " "
    }

    private var tint: Color {
        line.kind == .added ? .green.opacity(0.2) : line.kind == .removed ? .red.opacity(0.2) : line.kind == .hunk ? .accentColor.opacity(0.12) : .clear
    }

    private var label: String {
        switch line.kind {
        case .hunk: "Hunk \(line.text)"
        case .added: "Added, line \(line.new ?? 0): \(line.text)"
        case .removed: "Removed, line \(line.old ?? 0): \(line.text)"
        case .context: "Line \(line.new ?? 0): \(line.text)"
        }
    }
}
