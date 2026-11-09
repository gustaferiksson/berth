import Foundation
import Testing
@testable import BerthCore

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        let mixed = (state ^ (state >> 30)) &* 0xBF58_476D_1CE4_E5B9
        let remixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return remixed ^ (remixed >> 31)
    }
}

struct ReviewDiffTests {
    func visualRow(_ line: Int, _ side: ReviewDiff.Side) -> Int {
        line + side.fillerBeforeFirstLine + side.fillerAfterLine.filter { $0.key < line }.values.reduce(0, +)
    }

    func startRow(_ lines: Range<Int>, _ side: ReviewDiff.Side) -> Int {
        if !lines.isEmpty { return visualRow(lines.lowerBound, side) }
        return lines.lowerBound == 0 ? 0 : visualRow(lines.lowerBound - 1, side) + 1
    }

    func assertAligned(_ original: String, _ modified: String, sourceLocation: SourceLocation = #_sourceLocation) -> ReviewDiff {
        let diff = ReviewDiff(original: original, modified: modified)
        let oldLines = original.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)).replacing(/\r$/, with: "") }
        let newLines = modified.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)).replacing(/\r$/, with: "") }
        #expect(diff.original.lineCount == oldLines.count, sourceLocation: sourceLocation)
        #expect(diff.modified.lineCount == newLines.count, sourceLocation: sourceLocation)
        #expect(visualRow(diff.original.lineCount, diff.original) == visualRow(diff.modified.lineCount, diff.modified), sourceLocation: sourceLocation)

        let unchangedOld = (0..<oldLines.count).filter { !diff.original.changedLines.contains($0) }
        let unchangedNew = (0..<newLines.count).filter { !diff.modified.changedLines.contains($0) }
        #expect(unchangedOld.count == unchangedNew.count, sourceLocation: sourceLocation)
        for (old, new) in zip(unchangedOld, unchangedNew) {
            #expect(oldLines[old] == newLines[new], sourceLocation: sourceLocation)
            #expect(visualRow(old, diff.original) == visualRow(new, diff.modified), sourceLocation: sourceLocation)
        }
        for hunk in diff.hunks {
            #expect(startRow(hunk.originalLines, diff.original) == startRow(hunk.modifiedLines, diff.modified), sourceLocation: sourceLocation)
        }
        return diff
    }

    func words(_ text: String, _ ranges: [NSRange]) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    @Test func identicalTextsHaveNoChanges() {
        let diff = assertAligned("a\nb\nc\n", "a\nb\nc\n")
        #expect(diff.hunks.isEmpty)
        #expect(diff.original.changedLines.isEmpty && diff.modified.changedLines.isEmpty)
        #expect(diff.original.fillerAfterLine.isEmpty && diff.modified.fillerAfterLine.isEmpty)
    }

    @Test func replacedBlockPadsTheShorterSideAfterItsBlock() {
        let diff = assertAligned("a\nx1\nx2\nx3\nb\n", "a\ny1\ny2\ny3\ny4\ny5\nb\n")
        #expect(Array(diff.original.changedLines) == [1, 2, 3])
        #expect(Array(diff.modified.changedLines) == [1, 2, 3, 4, 5])
        #expect(diff.original.fillerAfterLine == [3: 2])
        #expect(diff.modified.fillerAfterLine.isEmpty)
        #expect(diff.hunks == [ReviewDiff.Hunk(originalLines: 1..<4, modifiedLines: 1..<6)])
    }

    @Test func addedAndRemovedBlocksPadTheOtherSide() {
        let diff = assertAligned("a\nb\nc\nd\n", "a\nnew1\nnew2\nb\nd\n")
        #expect(Array(diff.original.changedLines) == [2])
        #expect(Array(diff.modified.changedLines) == [1, 2])
        #expect(diff.original.fillerAfterLine == [0: 2])
        #expect(diff.modified.fillerAfterLine == [3: 1])
        #expect(diff.hunks.map(\.originalLines.lowerBound) == [1, 2])
        #expect(diff.hunks.map(\.modifiedLines.lowerBound) == [1, 4])
    }

    @Test func insertionAtTheTopPadsBeforeTheFirstLine() {
        let diff = assertAligned("a\nb\n", "x\ny\na\nb\n")
        #expect(diff.original.fillerBeforeFirstLine == 2)
        #expect(diff.original.fillerAfterLine.isEmpty)
    }

    @Test func addedAndDeletedFiles() {
        let added = assertAligned("", "a\nb\n")
        #expect(Array(added.modified.changedLines) == [0, 1])
        #expect(added.original.fillerBeforeFirstLine == 2)

        let deleted = assertAligned("a\nb\n", "")
        #expect(Array(deleted.original.changedLines) == [0, 1])
        #expect(deleted.modified.fillerBeforeFirstLine == 2)
    }

    @Test func trailingNewlineAddsAnEmptyLine() {
        let diff = assertAligned("a\nb", "a\nb\n")
        #expect(diff.original.changedLines.isEmpty)
        #expect(Array(diff.modified.changedLines) == [2])
        #expect(diff.original.fillerAfterLine == [1: 1])
    }

    @Test func lineEndingsAreIgnored() {
        let diff = assertAligned("a\nb\nc\n", "a\r\nb\r\nc\r\n")
        #expect(diff.hunks.isEmpty)
    }

    @Test func wordRangesCoverTheDifferingTokensInTextOffsets() {
        let original = "keep\r\nlet total = count + 1\nend\n"
        let modified = "keep\nlet sum = count + 2 // 🎉 done\nend\n"
        let diff = assertAligned(original, modified)
        #expect(words(original, diff.original.changedWordRangesInText) == ["total", "1"])
        #expect(words(modified, diff.modified.changedWordRangesInText) == ["sum", "2 // 🎉 done"])
    }

    @Test func dissimilarAndHugeLinesSkipWordRanges() {
        let dissimilar = assertAligned("alpha beta gamma\n", "one(two, three)\n")
        #expect(dissimilar.original.changedWordRangesInText.isEmpty && dissimilar.modified.changedWordRangesInText.isEmpty)

        let long = String(repeating: "word ", count: 300)
        let huge = assertAligned(long + "a\n", long + "b\n")
        #expect(huge.original.changedLines == [0])
        #expect(huge.modified.changedWordRangesInText.isEmpty)
    }

    @Test func veryDifferentTextsBecomeOneReplacedBlock() {
        let original = (0..<5000).map { "old line \($0)" }.joined(separator: "\n")
        let modified = (0..<5000).map { "new line \($0)" }.joined(separator: "\n")
        let diff = assertAligned(original, modified)
        #expect(diff.hunks == [ReviewDiff.Hunk(originalLines: 0..<5000, modifiedLines: 0..<5000)])
        #expect(diff.original.changedWordRangesInText.isEmpty)
    }

    @Test func randomEditsStayAligned() {
        var generator = SplitMix64(state: 42)
        for _ in 0..<200 {
            let original = (0..<200).map { _ in "line \(Int.random(in: 0..<40, using: &generator))" }
            var modified = original
            for _ in 0..<Int.random(in: 1...20, using: &generator) {
                let index = Int.random(in: 0...modified.count, using: &generator)
                let edit = Int.random(in: 0..<3, using: &generator)
                if edit == 0 { modified.insert("added \(index)", at: index) }
                if edit == 1, index < modified.count { modified.remove(at: index) }
                if edit == 2, index < modified.count { modified[index] += " changed" }
            }
            _ = assertAligned(original.joined(separator: "\n"), modified.joined(separator: "\n"))
        }
    }
}
