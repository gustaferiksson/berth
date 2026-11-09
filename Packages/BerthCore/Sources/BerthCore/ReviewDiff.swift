import Foundation

public struct ReviewDiff: Sendable, Equatable {
    public struct Side: Sendable, Equatable {
        public internal(set) var lineCount: Int
        public internal(set) var changedLines = IndexSet()
        public internal(set) var fillerBeforeFirstLine = 0
        public internal(set) var fillerAfterLine: [Int: Int] = [:]
        public internal(set) var changedWordRangesInText: [NSRange] = []

        mutating func addFiller(_ count: Int, afterLine line: Int) {
            guard count > 0 else { return }
            if line < 0 {
                fillerBeforeFirstLine += count
            } else {
                fillerAfterLine[line, default: 0] += count
            }
        }
    }

    public struct Hunk: Sendable, Equatable {
        public let originalLines: Range<Int>
        public let modifiedLines: Range<Int>
    }

    enum TokenKind {
        case word, space, punctuation
    }

    static let maxLineEditDistance = 3000
    static let maxWordDiffLineLength = 1000

    public let original: Side
    public let modified: Side
    public let hunks: [Hunk]

    public init(original originalText: String, modified modifiedText: String) {
        let old = Self.lines(of: originalText)
        let new = Self.lines(of: modifiedText)
        let oldLines = old.lines.map { old.units[$0] }
        let newLines = new.lines.map { new.units[$0] }

        let prefix = zip(oldLines, newLines).prefix { $0 == $1 }.count
        let suffix = zip(oldLines.dropFirst(prefix).reversed(), newLines.dropFirst(prefix).reversed()).prefix { $0 == $1 }.count
        var lineIDs: [ArraySlice<UInt16>: Int] = [:]
        for line in oldLines[prefix..<(oldLines.count - suffix)] + newLines[prefix..<(newLines.count - suffix)] where lineIDs[line] == nil {
            lineIDs[line] = lineIDs.count
        }
        let oldMiddle = oldLines[prefix..<(oldLines.count - suffix)].map { lineIDs[$0, default: -1] }
        let newMiddle = newLines[prefix..<(newLines.count - suffix)].map { lineIDs[$0, default: -1] }

        var lineBalance = [Int](repeating: 0, count: lineIDs.count)
        for id in oldMiddle { lineBalance[id] += 1 }
        for id in newMiddle { lineBalance[id] -= 1 }
        let isTooDifferent = lineBalance.reduce(0) { $0 + abs($1) } > Self.maxLineEditDistance

        let difference = isTooDifferent ? nil : newMiddle.difference(from: oldMiddle)
        let removed = difference.map { IndexSet($0.removals.compactMap { if case .remove(let offset, _, _) = $0 { prefix + offset } else { nil } }) }
            ?? IndexSet(integersIn: prefix..<(prefix + oldMiddle.count))
        let inserted = difference.map { IndexSet($0.insertions.compactMap { if case .insert(let offset, _, _) = $0 { prefix + offset } else { nil } }) }
            ?? IndexSet(integersIn: prefix..<(prefix + newMiddle.count))

        var original = Side(lineCount: oldLines.count)
        var modified = Side(lineCount: newLines.count)
        var hunks: [Hunk] = []
        var oldWords = IndexSet()
        var newWords = IndexSet()
        var i = 0
        var j = 0
        while i < oldLines.count || j < newLines.count {
            let oldStart = i
            let newStart = j
            while i < oldLines.count, removed.contains(i) { i += 1 }
            while j < newLines.count, inserted.contains(j) { j += 1 }
            guard i > oldStart || j > newStart else {
                i += 1
                j += 1
                continue
            }

            hunks.append(Hunk(originalLines: oldStart..<i, modifiedLines: newStart..<j))
            original.changedLines.insert(integersIn: oldStart..<i)
            modified.changedLines.insert(integersIn: newStart..<j)
            original.addFiller((j - newStart) - (i - oldStart), afterLine: i - 1)
            modified.addFiller((i - oldStart) - (j - newStart), afterLine: j - 1)

            guard !isTooDifferent else { continue }
            for pair in 0..<min(i - oldStart, j - newStart) {
                let words = Self.changedWords(oldLines[oldStart + pair], newLines[newStart + pair])
                oldWords.formUnion(words.old)
                newWords.formUnion(words.new)
            }
        }

        original.changedWordRangesInText = oldWords.rangeView.map { NSRange($0) }
        modified.changedWordRangesInText = newWords.rangeView.map { NSRange($0) }
        self.original = original
        self.modified = modified
        self.hunks = hunks
    }

    static func lines(of text: String) -> (units: [UInt16], lines: [Range<Int>]) {
        let units = Array(text.utf16)
        var lines: [Range<Int>] = []
        var start = 0
        for (offset, unit) in units.enumerated() where unit == 0x0A {
            lines.append(start..<(offset > start && units[offset - 1] == 0x0D ? offset - 1 : offset))
            start = offset + 1
        }
        lines.append(start..<units.count)
        return (units, lines)
    }

    static func changedWords(_ old: ArraySlice<UInt16>, _ new: ArraySlice<UInt16>) -> (old: IndexSet, new: IndexSet) {
        guard max(old.count, new.count) <= maxWordDiffLineLength else { return (IndexSet(), IndexSet()) }

        let oldTokens = tokens(of: old)
        let newTokens = tokens(of: new)

        var unmatchedOld: [ArraySlice<UInt16>: Int] = [:]
        var oldSolidLength = 0
        for token in oldTokens where token.kind != .space {
            unmatchedOld[old[token.range], default: 0] += 1
            oldSolidLength += token.range.count
        }
        var newSolidLength = 0
        var matchableLength = 0
        for token in newTokens where token.kind != .space {
            newSolidLength += token.range.count
            guard let count = unmatchedOld[new[token.range]], count > 0 else { continue }
            unmatchedOld[new[token.range]] = count - 1
            matchableLength += token.range.count
        }
        guard matchableLength * 3 >= max(oldSolidLength, newSolidLength) else { return (IndexSet(), IndexSet()) }

        var oldChanged = IndexSet()
        var newChanged = IndexSet()
        for change in newTokens.map({ new[$0.range] }).difference(from: oldTokens.map { old[$0.range] }) {
            if case .remove(let offset, _, _) = change { oldChanged.insert(integersIn: oldTokens[offset].range) }
            if case .insert(let offset, _, _) = change { newChanged.insert(integersIn: newTokens[offset].range) }
        }
        return (oldChanged, newChanged)
    }

    static func tokens(of units: ArraySlice<UInt16>) -> [(range: Range<Int>, kind: TokenKind)] {
        var tokens: [(range: Range<Int>, kind: TokenKind)] = []
        var previousKind: TokenKind?
        var offset = units.startIndex
        for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
            let kind: TokenKind = scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" ? .word : scalar.properties.isWhitespace ? .space : .punctuation
            let end = offset + UTF16.width(scalar)
            if kind != .punctuation, kind == previousKind, let last = tokens.last {
                tokens[tokens.count - 1].range = last.range.lowerBound..<end
            } else {
                tokens.append((offset..<end, kind))
            }
            previousKind = kind
            offset = end
        }
        return tokens
    }
}
