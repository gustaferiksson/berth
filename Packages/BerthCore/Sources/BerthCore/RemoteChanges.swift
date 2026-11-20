import Foundation

public extension RemoteChanges {
    init(_ changes: ReviewChanges) {
        let file = { (file: ReviewFile) in RemoteChangedFile(path: file.path, oldPath: file.oldPath, status: file.status.rawValue, additions: file.additions, deletions: file.deletions) }
        self.init(
            branch: changes.branch,
            base: changes.isDefaultBranch ? nil : changes.base,
            uncommitted: changes.uncommitted.prefix(RemoteChangesFeature.maxFiles).map(file),
            committed: changes.committed.prefix(RemoteChangesFeature.maxFiles).map(file),
            isTruncated: max(changes.uncommitted.count, changes.committed.count) > RemoteChangesFeature.maxFiles
        )
    }
}

extension RemoteFileDiff {
    public init(_ contents: ReviewContents, context: Int = 3, maxBytes: Int = RemoteChangesFeature.maxDiffBytes) {
        self = Self.build(contents, context: context, maxBytes: maxBytes)
    }

    private static func build(_ contents: ReviewContents, context: Int, maxBytes: Int) -> Self {
        let sides = [contents.original, contents.modified]
        guard !sides.contains(.binary) else { return Self(lines: [], isBinary: true, isTruncated: false) }
        guard !sides.contains(where: { if case .tooLarge = $0 { true } else { false } }) else { return Self(lines: [], isBinary: false, isTruncated: true) }

        let old = lines(of: contents.original)
        let new = lines(of: contents.modified)
        let hunks = if old.isEmpty || new.isEmpty {
            old.isEmpty && new.isEmpty ? [] : [ReviewDiff.Hunk(originalLines: 0..<old.count, modifiedLines: 0..<new.count)]
        } else {
            ReviewDiff(original: old.joined(separator: "\n"), modified: new.joined(separator: "\n")).hunks
        }

        var lines: [RemoteDiffLine] = []
        var bytes = 0
        var index = 0
        while index < hunks.count {
            var last = index
            while last + 1 < hunks.count, hunks[last + 1].originalLines.lowerBound - hunks[last].originalLines.upperBound <= 2 * context { last += 1 }

            let oldStart = max(0, hunks[index].originalLines.lowerBound - context)
            let oldEnd = min(old.count, hunks[last].originalLines.upperBound + context)
            let newStart = hunks[index].modifiedLines.lowerBound - (hunks[index].originalLines.lowerBound - oldStart)
            let newEnd = hunks[last].modifiedLines.upperBound + (oldEnd - hunks[last].originalLines.upperBound)
            let header = "@@ -\(oldEnd == oldStart ? oldStart : oldStart + 1),\(oldEnd - oldStart) +\(newEnd == newStart ? newStart : newStart + 1),\(newEnd - newStart) @@"

            var rows = [RemoteDiffLine(kind: .hunk, old: nil, new: nil, text: header)]
            var oldIndex = oldStart
            var newIndex = newStart
            for hunk in hunks[index...last] {
                while oldIndex < hunk.originalLines.lowerBound {
                    rows.append(RemoteDiffLine(kind: .context, old: oldIndex + 1, new: newIndex + 1, text: old[oldIndex]))
                    oldIndex += 1
                    newIndex += 1
                }
                rows += hunk.originalLines.map { RemoteDiffLine(kind: .removed, old: $0 + 1, new: nil, text: old[$0]) }
                rows += hunk.modifiedLines.map { RemoteDiffLine(kind: .added, old: nil, new: $0 + 1, text: new[$0]) }
                oldIndex = hunk.originalLines.upperBound
                newIndex = hunk.modifiedLines.upperBound
            }
            while oldIndex < oldEnd {
                rows.append(RemoteDiffLine(kind: .context, old: oldIndex + 1, new: newIndex + 1, text: old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }

            for row in rows {
                guard bytes < maxBytes else { return Self(lines: lines, isBinary: false, isTruncated: true) }

                lines.append(row)
                bytes += row.text.utf8.count
            }
            index = last + 1
        }
        return Self(lines: lines, isBinary: false, isTruncated: false)
    }

    private static func lines(of text: ReviewText?) -> [String] {
        guard case let .text(text)? = text, !text.isEmpty else { return [] }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        return text.hasSuffix("\n") ? Array(lines.dropLast()) : lines
    }
}
