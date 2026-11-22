import Foundation

public struct ToolDiffRow: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable {
        case context, added, removed
    }

    public let id: Int
    public let kind: Kind
    public let text: String
}

public enum ToolDiff {
    public static func rows(old: String, new: String) -> [ToolDiffRow] {
        let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        let removed = Set(difference.removals.compactMap { if case let .remove(offset, _, _) = $0 { offset } else { nil } })
        let inserted = Set(difference.insertions.compactMap { if case let .insert(offset, _, _) = $0 { offset } else { nil } })
        var rows: [ToolDiffRow] = []
        var i = 0
        var j = 0
        while i < before.count || j < after.count {
            let kind: ToolDiffRow.Kind
            let text: String
            if i < before.count, removed.contains(i) {
                (kind, text) = (.removed, before[i])
                i += 1
            } else if j < after.count, inserted.contains(j) {
                (kind, text) = (.added, after[j])
                j += 1
            } else if i < before.count {
                (kind, text) = (.context, before[i])
                i += 1
                j += 1
            } else {
                break
            }
            rows.append(ToolDiffRow(id: rows.count, kind: kind, text: text))
        }
        return rows
    }
}
