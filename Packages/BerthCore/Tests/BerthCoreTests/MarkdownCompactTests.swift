import BerthCore
import Foundation
import Testing

struct MarkdownCompactTests {
    @Test func stylesInlineAndStripsBlockSyntax() {
        let text = "## Plan\n**Bold** and `code`\n- first\n  - nested\n1. second\n![shot](a.png)\n```swift\nlet x = 1\n```"
        let result = MarkdownBlock.compact(text)

        #expect(String(result.characters) == "Plan\nBold and code\n• first\n  • nested\n1. second\nlet x = 1")
    }
}
