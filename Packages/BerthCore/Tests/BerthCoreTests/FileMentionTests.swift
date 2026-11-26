@testable import BerthCore
import Testing

struct FileMentionTests {
    private let files: Set<String> = [
        "/home/ann/Screens/Screen Recording 1.mov",
        "/home/ann/Screens/Screen",
        "/work/app/notes.md",
        "/work/app/Sources/main.swift",
    ]

    private func extract(_ text: String) -> (text: String, mentions: [FileMention]) {
        FileMentions.extract(from: text, folder: "/work/app") { files.contains($0) }
    }

    @Test func takesTheLongestPrefixThatExists() {
        let result = extract("@/home/ann/Screens/Screen Recording 1.mov break this down")

        #expect(result.mentions.map(\.path) == ["/home/ann/Screens/Screen Recording 1.mov"])
        #expect(result.text == "break this down")
    }

    @Test func resolvesRelativePathsAgainstTheFolder() {
        let result = extract("read @notes.md, then @./Sources/main.swift.")

        #expect(result.mentions.map(\.path) == ["/work/app/notes.md", "/work/app/Sources/main.swift"])
        #expect(result.text == "read @notes.md, then @main.swift.")
    }

    @Test func keepsAShortenedMentionInTheMiddle() {
        #expect(extract("compare @notes.md with the rest").text == "compare @notes.md with the rest")
    }

    @Test func keepsMissingAbsolutePathsAsMissing() {
        let result = extract("see @/gone/a b.png now")

        #expect(result.mentions == [FileMention(path: "/gone/a", exists: false)])
        #expect(result.text == "see @a b.png now")
    }

    @Test func ignoresHandlesAndEmail() {
        let result = extract("ping @claude or me@notes.md")

        #expect(result.mentions.isEmpty)
        #expect(result.text == "ping @claude or me@notes.md")
    }

    @Test func unescapesBackslashSpaces() {
        let result = extract("@/home/ann/Screens/Screen\\ Recording\\ 1.mov hi")

        #expect(result.mentions.map(\.path) == ["/home/ann/Screens/Screen Recording 1.mov"])
    }
}
