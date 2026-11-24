@testable import BerthCore
import Testing

struct MarkdownFrontmatterTests {
    @Test func readsTopLevelKeysAndBody() throws {
        let frontmatter = try #require(MarkdownFrontmatter.split("---\ntitle: Plan\nstatus: \"draft\"\nowner: 'sam'\n# note\n\nurl: https://example.com/a\n---\n# Heading\n\nText\n"))

        #expect(frontmatter.content == .entries([
            .init(key: "title", value: "Plan", isNested: false),
            .init(key: "status", value: "draft", isNested: false),
            .init(key: "owner", value: "sam", isNested: false),
            .init(key: "url", value: "https://example.com/a", isNested: false),
        ]))
        #expect(frontmatter.body == "# Heading\n\nText\n")
    }

    @Test func keepsNestedValuesAsRawYAML() throws {
        let frontmatter = try #require(MarkdownFrontmatter.split("---\ntags:\n  - a\n  - b\nmeta:\n  k: v\nlist:\n- x\nflow: [a, b]\nnote: |\n  one\n\n  two\nafter: ok\n---\nBody"))

        #expect(frontmatter.content == .entries([
            .init(key: "tags", value: "  - a\n  - b", isNested: true),
            .init(key: "meta", value: "  k: v", isNested: true),
            .init(key: "list", value: "- x", isNested: true),
            .init(key: "flow", value: "[a, b]", isNested: true),
            .init(key: "note", value: "|\n  one\n\n  two", isNested: true),
            .init(key: "after", value: "ok", isNested: false),
        ]))
    }

    @Test func keyWithoutValueIsEmptyScalar() throws {
        let frontmatter = try #require(MarkdownFrontmatter.split("---\ndraft:\n---\n"))

        #expect(frontmatter.content == .entries([.init(key: "draft", value: "", isNested: false)]))
    }

    @Test func fallsBackToRawWhenALineIsNotYAMLKeys() throws {
        let frontmatter = try #require(MarkdownFrontmatter.split("---\njust some words\ntitle: x\n---\nBody"))

        #expect(frontmatter.content == .raw("just some words\ntitle: x"))
        #expect(frontmatter.body == "Body")
    }

    @Test func closesOnDocumentEndMarker() throws {
        let frontmatter = try #require(MarkdownFrontmatter.split("---\ntitle: x\n...\nBody"))

        #expect(frontmatter.content == .entries([.init(key: "title", value: "x", isNested: false)]))
        #expect(frontmatter.body == "Body")
    }

    @Test func handlesCRLFAndByteOrderMark() throws {
        let frontmatter = try #require(MarkdownFrontmatter.split("\u{FEFF}---\r\ntitle: x\r\n---\r\nBody\r\nMore"))

        #expect(frontmatter.content == .entries([.init(key: "title", value: "x", isNested: false)]))
        #expect(frontmatter.body == "Body\nMore")
    }

    @Test func emptyBlockHasNoEntries() throws {
        let frontmatter = try #require(MarkdownFrontmatter.split("---\n---\nBody"))

        #expect(frontmatter.content == .entries([]))
    }

    @Test func ignoresWhatIsNotFrontmatter() {
        #expect(MarkdownFrontmatter.split("---\ntitle: x\nno closing fence") == nil)
        #expect(MarkdownFrontmatter.split("\n---\ntitle: x\n---\nBody") == nil)
        #expect(MarkdownFrontmatter.split("# Title\n\n---\ntitle: x\n---\n") == nil)
        #expect(MarkdownFrontmatter.split("----\ntitle: x\n---\n") == nil)
    }
}
