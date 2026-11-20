@testable import BerthCore
import Foundation
import Testing

struct LoopbackURLTests {
    @Test func acceptsLoopbackHosts() {
        for text in ["localhost:5173", "http://127.0.0.1:3000/a?b=1", "https://localhost", "http://[::1]:8080/", "HTTP://LOCALHOST:1"] {
            #expect(LoopbackURL.parse(text) != nil, "\(text)")
        }
    }

    @Test func rejectsEverythingElse() {
        for text in ["example.com", "http://localhost.evil.com", "http://localhost@evil.com", "http://evil.com#localhost", "file:///etc/passwd", "javascript:alert(1)", "http://192.168.1.2:3000", "http://0.0.0.0:80", "ftp://localhost", ""] {
            #expect(LoopbackURL.parse(text) == nil, "\(text)")
        }
    }

    @Test func elementCommentPromptNamesSelectorAndScreenshot() {
        let element = ReviewComment.Element(url: "http://localhost:5173/", selector: "main > button", html: "<button>Go</button>", imagePath: "/tmp/pick.png")
        let comment = ReviewComment(id: "e", path: element.url, line: 0, endLine: 0, text: "Make it blue", snippet: "", compare: nil, element: element)
        let prompt = ReviewComment.prompt(for: [comment], branch: "b", base: "main")
        #expect(prompt.contains("Preview element `main > button` on http://localhost:5173/"))
        #expect(prompt.contains("<button>Go</button>"))
        #expect(prompt.contains("Screenshot: /tmp/pick.png\nMake it blue"))
    }
}
