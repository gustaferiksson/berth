@testable import BerthCore
import Foundation
import Testing

struct CodeWordRangeTests {
    private let text = "repository.getRoles()  \n$x_1"

    private func word(_ location: Int, length: Int = 0) -> String {
        let range = CodeWordRange.expand(NSRange(location: location, length: length), in: text as NSString)
        return (text as NSString).substring(with: range)
    }

    @Test func selectsOnlyTheIdentifierBeforeAPeriod() {
        #expect(word(3) == "repository")
        #expect(word(11) == "getRoles")
    }

    @Test func punctuationAndWhitespaceRunsAreTheirOwnUnits() {
        #expect(word(10) == ".")
        #expect(word(19) == "()")
        #expect(word(21) == "  ")
        #expect(word(23) == "\n")
        #expect(word(25) == "$x_1")
    }

    @Test func dragExtendsAcrossUnits() {
        #expect(word(3, length: 9) == "repository.getRoles")
    }
}
