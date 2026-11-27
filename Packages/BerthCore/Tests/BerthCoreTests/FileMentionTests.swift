@testable import BerthCore
import Testing

struct FileMentionTests {
    private let files: Set<String> = [
        "/home/ann/Screens/Screen Recording 1.mov",
        "/home/ann/Screens/Screen",
        "/work/app/notes.md",
        "/work/app/Sources/main.swift",
    ]

    private func extract(_ text: String) -> (text: String, occurrences: [FileMentions.Occurrence]) {
        FileMentions.extract(from: text, folder: "/work/app") { files.contains($0) }
    }

    @Test func takesTheLongestPrefixThatExists() {
        let text = "  @/home/ann/Screens/Screen Recording 1.mov break this down\n"
        let result = extract(text)

        #expect(result.occurrences.map(\.mention.path) == ["/home/ann/Screens/Screen Recording 1.mov"])
        #expect(result.occurrences.map(\.token) == ["@/home/ann/Screens/Screen Recording 1.mov"])
        #expect(result.text == text)
    }

    @Test func resolvesRelativePathsAgainstTheFolder() {
        let text = "read @notes.md, then @./Sources/main.swift."
        let result = extract(text)

        #expect(result.occurrences.map(\.mention.path) == ["/work/app/notes.md", "/work/app/Sources/main.swift"])
        #expect(result.occurrences.map(\.token) == ["@notes.md", "@./Sources/main.swift"])
        #expect(result.text == text)
    }

    @Test func keepsEveryOccurrenceOfTheSamePath() {
        let text = "Compare @notes.md with @./notes.md and @notes.md"
        let result = extract(text)

        #expect(result.occurrences.map(\.token) == ["@notes.md", "@./notes.md", "@notes.md"])
        #expect(result.occurrences.map(\.mention.path) == Array(repeating: "/work/app/notes.md", count: 3))
        #expect(result.text == text)
    }

    @Test func keepsMissingAbsolutePathsAsMissing() {
        let text = "see @/gone/a b.png and @/gone/a\\ b.png now"
        let result = extract(text)

        #expect(result.occurrences.map(\.mention) == [
            FileMention(path: "/gone/a", exists: false),
            FileMention(path: "/gone/a b.png", exists: false),
        ])
        #expect(result.occurrences.map(\.token) == ["@/gone/a", "@/gone/a\\ b.png"])
        #expect(result.text == text)
    }

    @Test func ignoresHandlesAndEmail() {
        let result = extract("ping @claude or me@notes.md")

        #expect(result.occurrences.isEmpty)
        #expect(result.text == "ping @claude or me@notes.md")
    }

    @Test func preservesEscapesAndSourceIndices() throws {
        let text = "first\n[Image #1] 🗂 @/home/ann/Screens/Screen\\ Recording\\ 1.mov"
        let token = "@/home/ann/Screens/Screen\\ Recording\\ 1.mov"
        let prefix = try #require(text.firstRange(of: "@"))
        let line = try #require(text.split(separator: /\n/).last)
        let values = PromptTextPart.split(line).compactMap { part -> Substring? in
            if case let .text(value) = part { return value }
            return nil
        }
        let prose = try #require(values.last)
        let result = FileMentions.extract(from: prose, folder: "/work/app") { files.contains($0) }
        let occurrence = try #require(result.occurrences.first)

        #expect(occurrence.mention.path == "/home/ann/Screens/Screen Recording 1.mov")
        #expect(occurrence.token == token)
        #expect(occurrence.token.startIndex == prefix.lowerBound)
        #expect(result.text == prose)
    }
}
