@testable import BerthCore
import Foundation
import Testing

struct TextEditTests {
    @Test func keepsCaretAfterAnEditAboveIt() {
        let edit = TextEdit(from: "# Title\nbody text\n", to: "# New title\nbody text\n")
        #expect(edit.mapped(14) == 18)
    }

    @Test func keepsCaretBeforeAnEditBelowIt() {
        let edit = TextEdit(from: "one\ntwo\n", to: "one\ntwo\nthree\n")
        #expect(edit.mapped(2) == 2)
    }

    @Test func movesCaretInsideReplacedTextToItsStart() {
        let edit = TextEdit(from: "abcdef", to: "abXYZf")
        #expect(edit.range == NSRange(location: 2, length: 3))
        #expect(edit.mapped(4) == 2)
    }

    @Test func identicalTextIsAnEmptyEdit() {
        let edit = TextEdit(from: "same", to: "same")
        #expect(edit.range.length == 0 && edit.replacement.isEmpty)
    }
}
