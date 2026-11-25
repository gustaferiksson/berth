import BerthCore
import Foundation
import Testing

struct SlashTokenTests {
    private func find(_ text: String, caretAfter marker: String? = nil) -> (query: String, replacing: String)? {
        let caret = marker.flatMap { text.range(of: $0)?.upperBound } ?? text.endIndex
        return SlashToken.find(in: text, caret: caret).map { ($0.query, String(text[$0.replacing])) }
    }

    @Test func opensAtStartAndAfterWhitespace() {
        #expect(find("/co")?.query == "/co")
        #expect(find("fix this /sk")?.query == "/sk")
        #expect(find("line\n/sk")?.query == "/sk")
    }

    @Test func ignoresPathsAndWords() {
        #expect(find("see ./foo") == nil)
        #expect(find("a/b") == nil)
        #expect(find("https://x.dev/a") == nil)
        #expect(find("hello") == nil)
    }

    @Test func filtersByTextBeforeCaretAndReplacesWholeToken() {
        let result = find("use /skill now", caretAfter: "/sk")
        #expect(result?.query == "/sk")
        #expect(result?.replacing == "/skill ")
    }

    @Test func ignoresCaretOutsideToken() {
        #expect(find("/skill now", caretAfter: "now") == nil)
        #expect(find("/skill now", caretAfter: "/skill ") == nil)
    }
}
