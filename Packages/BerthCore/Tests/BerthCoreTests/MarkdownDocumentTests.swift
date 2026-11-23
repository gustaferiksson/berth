@testable import BerthCore
import Foundation
import Testing

struct MarkdownDocumentTests {
    @Test func readsEveryBlockKind() throws {
        let source = """
        # Title

        Text with `code`.

        ---

        - [ ] open
        - [x] done
          - nested

        3. three
        4. four

        > quoted

        | A | B |
        |---|---|
        | 1 | |

        ```swift
        let x = 1
        ```

        ![shot](img/a.png)
        """
        let nodes = MarkdownDocument.nodes(in: source)

        #expect(nodes.count == 9)
        try #require(nodes.count == 9)

        #expect(nodes[0] == .heading(1, AttributedString("Title")))
        #expect(nodes[2] == .rule)
        #expect(nodes[7] == .code(language: "swift", text: "let x = 1"))
        #expect(nodes[8] == .images([MarkdownImage(source: "img/a.png", alt: "shot")]))

        guard case let .list(bullets, items) = nodes[3] else {
            Issue.record("expected a list")
            return
        }

        #expect(bullets == nil)
        #expect(items.map(\.checked) == [false, true])
        guard case let .paragraph(open)? = items[0].content.first else {
            Issue.record("expected a paragraph")
            return
        }

        #expect(String(open.characters) == "open")
        guard case .list = items[1].content.last else {
            Issue.record("expected a nested list")
            return
        }
        guard case let .list(start, _) = nodes[4] else {
            Issue.record("expected an ordered list")
            return
        }

        #expect(start == 3)
        guard case let .quote(quoted) = nodes[5] else {
            Issue.record("expected a quote")
            return
        }

        #expect(quoted == [.paragraph(AttributedString("quoted"))])
        guard case let .table(rows) = nodes[6] else {
            Issue.record("expected a table")
            return
        }

        #expect(rows.map { $0.map { String($0.characters) } } == [["A", "B"], ["1", ""]])
    }

    @Test func recognisesMarkdownPaths() {
        #expect(MarkdownDocument.isMarkdown(path: "docs/README.MD"))
        #expect(MarkdownDocument.isMarkdown(path: "notes.markdown"))
        #expect(!MarkdownDocument.isMarkdown(path: "main.swift"))
    }
}
