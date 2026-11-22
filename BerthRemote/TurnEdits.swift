import SwiftUI

struct EditHunk {
    enum Kind { case context, added, removed }

    struct Row: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    let old: String?
    let new: String

    var rows: [Row] {
        let newLines = Self.lines(new)
        guard let old else { return newLines.enumerated().map { Row(id: $0.offset, kind: .added, text: $0.element) } }

        let oldLines = Self.lines(old)
        let difference = newLines.difference(from: oldLines)
        let removed = Set(difference.removals.compactMap { change -> Int? in if case let .remove(offset, _, _) = change { offset } else { nil } })
        let inserted = Set(difference.insertions.compactMap { change -> Int? in if case let .insert(offset, _, _) = change { offset } else { nil } })
        var rows: [Row] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                rows.append(Row(id: rows.count, kind: .removed, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                rows.append(Row(id: rows.count, kind: .added, text: newLines[newIndex]))
                newIndex += 1
            } else {
                rows.append(Row(id: rows.count, kind: .context, text: newIndex < newLines.count ? newLines[newIndex] : oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }
        return rows
    }

    static func lines(_ text: String) -> [String] {
        text.hasSuffix("\n") ? text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func hunks(of use: RemoteEntry) -> [Self] {
        guard use.name == "MultiEdit" else { return use.newText.map { [Self(old: use.oldText, new: $0)] } ?? [] }

        let input = try? JSONSerialization.jsonObject(with: Data(use.text.utf8)) as? [String: Any]
        return (input?["edits"] as? [[String: Any]] ?? []).compactMap { edit in
            guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else { return nil }

            return Self(old: old, new: new)
        }
    }
}

struct FileEdit: Identifiable {
    let path: String
    var hunks: [EditHunk] = []
    var isCounted = true

    var id: String { path }

    var counts: (added: Int, removed: Int)? {
        guard isCounted, !hunks.isEmpty else { return nil }

        let rows = hunks.flatMap(\.rows)
        return (rows.count { $0.kind == .added }, rows.count { $0.kind == .removed })
    }
}

extension Turn {
    var fileEdits: [FileEdit] {
        let calls = parts.flatMap { part -> [ToolCall] in
            guard case let .work(calls) = part else { return [] }

            return calls.filter { $0.kind == .edit && $0.result != nil && $0.result?.isError != true }
        }
        var edits: [FileEdit] = []
        for call in calls {
            let path = call.use.filePath ?? call.id
            let hunks = EditHunk.hunks(of: call.use)
            let index = edits.firstIndex { $0.path == path } ?? edits.endIndex
            if index == edits.endIndex { edits.append(FileEdit(path: path)) }
            edits[index].hunks += hunks
            edits[index].isCounted = edits[index].isCounted && !hunks.isEmpty && hunks.allSatisfy { $0.old != nil }
        }
        return edits
    }
}

struct ChangedFilesCard: View {
    let edits: [FileEdit]
    let openChanges: (() -> Void)?

    @State private var isExpanded = UserDefaults.standard.bool(forKey: "snapshotExpandedEdits")

    var body: some View {
        let counts = edits.map(\.counts)
        let total = counts.allSatisfy { $0 != nil } ? counts.compactMap(\.self).reduce((added: 0, removed: 0)) { ($0.added + $1.added, $0.removed + $1.removed) } : nil

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Edited \(edits.count) \(edits.count == 1 ? "file" : "files")")
                        .font(.subheadline.weight(.semibold))
                    if let total {
                        DiffCounts(added: total.added, removed: total.removed)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(edits) { edit in
                        Divider()
                        FileEditRow(edit: edit)
                    }
                    if let openChanges {
                        Button("Current Changes", systemImage: "plusminus", action: openChanges)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .padding(.vertical, 10)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
    }
}

private struct DiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        Text("\(Text("+\(added)").foregroundStyle(.green)) \(Text("−\(removed)").foregroundStyle(.red))")
            .font(.footnote.monospacedDigit())
    }
}

private struct FileEditRow: View {
    let edit: FileEdit

    @State private var isOpen = UserDefaults.standard.bool(forKey: "snapshotExpandedEdits")
    @State private var showsAll = false

    private let collapsedRows = 12

    var body: some View {
        let url = URL(filePath: edit.path)
        let folder = url.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: "/")

        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth) { isOpen.toggle() }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: url.lastPathComponent)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    if let counts = edit.counts {
                        DiffCounts(added: counts.added, removed: counts.removed)
                    }
                    if !edit.hunks.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isOpen ? 0 : -90))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(edit.hunks.isEmpty)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            if isOpen {
                hunks
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    private var hunks: some View {
        let total = edit.hunks.reduce(0) { $0 + $1.rows.count }
        var budget = showsAll ? Int.max : collapsedRows
        let shown = edit.hunks.map { hunk -> [EditHunk.Row] in
            let rows = Array(hunk.rows.prefix(max(budget, 0)))
            budget -= rows.count
            return rows
        }

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(shown.indices, id: \.self) { index in
                if !shown[index].isEmpty {
                    VStack(spacing: 0) {
                        ForEach(shown[index]) { DiffLine(row: $0) }
                    }
                    .background(.background, in: .rect(cornerRadius: 10))
                    .clipShape(.rect(cornerRadius: 10))
                }
            }
            if !showsAll, total > collapsedRows {
                Button("Show \(total - collapsedRows) More Lines") {
                    withAnimation(.smooth) { showsAll = true }
                }
                .font(.footnote)
            }
        }
    }
}

private struct DiffLine: View {
    let row: EditHunk.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                .foregroundStyle(row.kind == .added ? .green : row.kind == .removed ? .red : .secondary)
            Text(verbatim: row.text.isEmpty ? " " : row.text)
                .foregroundStyle(row.kind == .context ? .secondary : .primary)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Rectangle().fill(row.kind == .added ? Color.green.opacity(0.18) : row.kind == .removed ? Color.red.opacity(0.18) : .clear) }
    }
}
