@testable import BerthCore
import Foundation
import Testing

struct ReviewBlameTests {
    @Test func reusesCommitMetadataAndIndexesByFinalLine() {
        let hash = "1234567890abcdef1234567890abcdef12345678"
        let zeroHash = String(repeating: "0", count: 40)
        let entries = ReviewBlame.parse("""
        \(hash) 8 1 2
        author Renée Example
        author-mail <renee@example.invalid>
        author-time 1700000000
        author-tz -0500
        summary Add the sample
        boundary
        filename file with spaces.txt
        \tfirst line\r
        \(hash) 9 2
        \tauthor Not metadata
        \(zeroHash) 3 3 1
        author External file (--contents)
        author-time 1700000001
        summary Version from standard input
        filename file with spaces.txt
        \t
        \(hash) 16 4 1
        \tlast line
        """)

        #expect(entries.keys.sorted() == [1, 2, 3, 4])
        #expect(entries[1]?.hash == hash)
        #expect(entries[1]?.author == "Renée Example")
        #expect(entries[1]?.authorTime == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(entries[1]?.summary == "Add the sample")
        #expect(entries[1]?.isUncommitted == false)
        #expect(entries[2] == entries[1])
        #expect(entries[3]?.hash == zeroHash)
        #expect(entries[3]?.isUncommitted == true)
        #expect(entries[4] == entries[1])
    }

    @Test func parsesSHA256AndSkipsIncompleteRecords() {
        let hash = String(repeating: "a", count: 64)
        let entries = ReviewBlame.parse("""
        \(String(repeating: "b", count: 64)) 1 1 1
        author Incomplete
        \tone
        \(hash) 2 2 1
        author Example Author
        author-time 0
        summary\u{20}
        filename example.txt
        \ttwo
        \(hash) 3 3
        """)

        #expect(entries.keys.sorted() == [2])
        #expect(entries[2]?.hash == hash)
        #expect(entries[2]?.summary.isEmpty == true)
        #expect(ReviewBlame.parse("").isEmpty)
    }
}
