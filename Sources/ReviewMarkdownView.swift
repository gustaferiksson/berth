import AppKit
import BerthCore
import SwiftUI

struct ReviewMarkdownContext {
    let root: URL
    let open: (String) -> Void
}

extension ReviewDocument {
    var isMarkdown: Bool { compare == nil && MarkdownDocument.isMarkdown(path: path) }
}

struct ReviewMarkdownView: View {
    let text: String
    let path: String
    let context: ReviewMarkdownContext
    let style: ReviewStyle

    @Environment(\.openURL) private var openURL
    @State private var nodes: [MarkdownNode] = []
    @State private var frontmatter: MarkdownFrontmatter?

    var body: some View {
        let root = context.root.resolvingSymlinksInPath()
        let directory = context.root.appending(path: path).deletingLastPathComponent().resolvingSymlinksInPath()
        let markdown = MarkdownRenderStyle(style: style, source: .document(directory: directory, root: root))
        ScrollView {
            VStack(alignment: .leading, spacing: markdown.size) {
                if let frontmatter { MarkdownFrontmatterView(content: frontmatter.content, markdown: markdown) }
                ForEach(nodes.enumerated(), id: \.offset) { _, node in
                    MarkdownNodeView(node: node, markdown: markdown)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .task(id: text) {
            let parsed = await Task.detached {
                let frontmatter = MarkdownFrontmatter.split(text)
                return (frontmatter, MarkdownDocument.nodes(in: frontmatter?.body ?? text))
            }.value
            frontmatter = parsed.0
            nodes = parsed.1
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == nil else {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) { openURL(url) }
                return .handled
            }
            guard let file = markdown.localURL(for: url.absoluteString), (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return .handled }

            context.open(String(file.path.dropFirst(root.path.count + 1)))
            return .handled
        })
    }
}

struct MarkdownRenderStyle {
    enum Source {
        case document(directory: URL, root: URL)
        case preview
    }

    let style: ReviewStyle
    let source: Source
    let size: CGFloat
    var foreground: Color

    init(style: ReviewStyle, source: Source, size: CGFloat? = nil) {
        self.style = style
        self.source = source
        self.size = size ?? (style.font.pointSize + 2)
        foreground = Color(nsColor: style.foreground)
    }

    var secondary: Color { Color(nsColor: style.secondary) }

    var dimmed: Self {
        var copy = self
        copy.foreground = secondary
        return copy
    }

    func prose(_ text: AttributedString) -> AttributedString {
        var result = text
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].foregroundColor = Color(nsColor: style.inlineCode)
                result[run.range].font = Font(style.font.withSize(size - 1))
            } else if run.link != nil {
                result[run.range].foregroundColor = Color(nsColor: style.link)
            }
        }
        return result
    }

    func localURL(for source: String) -> URL? {
        guard case let .document(directory, root) = self.source,
              let url = URL(string: source), url.scheme == nil, !url.path.isEmpty else { return nil }

        let resolved = (url.path.hasPrefix("/") ? root.appending(path: url.path) : directory.appending(path: url.path)).resolvingSymlinksInPath()
        return resolved.path.hasPrefix(root.path + "/") ? resolved : nil
    }
}

struct MarkdownNodeView: View {
    let node: MarkdownNode
    let markdown: MarkdownRenderStyle

    var body: some View {
        if case let .heading(level, text) = node {
            let scale = [1.9, 1.5, 1.25, 1.1, 1, 1][level - 1]
            VStack(alignment: .leading, spacing: 8) {
                Text(markdown.prose(text))
                    .font(.system(size: markdown.size * scale, weight: .bold))
                    .foregroundStyle(level == 6 ? markdown.secondary : markdown.foreground)
                    .padding(.top, level <= 2 ? 8 : 4)
                if level <= 2 { Divider() }
            }
        } else if case let .paragraph(text) = node {
            Text(markdown.prose(text))
                .font(.system(size: markdown.size))
                .lineSpacing(markdown.size * 0.3)
                .foregroundStyle(markdown.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if case let .images(images) = node {
            HStack(alignment: .top, spacing: 8) {
                ForEach(images.enumerated(), id: \.offset) { _, image in
                    MarkdownImageView(image: image, markdown: markdown)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if case let .code(language, text) = node {
            MarkdownCodeBlock(language: language, text: text, markdown: markdown)
        } else if case let .quote(nodes) = node {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(nodes.enumerated(), id: \.offset) { _, node in Self(node: node, markdown: markdown.dimmed) }
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(markdown.secondary.opacity(0.4))
                    .frame(width: 3)
            }
        } else if case let .list(start, items) = node {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.enumerated(), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(start: start, index: index, checked: item.checked)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(item.content.enumerated(), id: \.offset) { _, node in Self(node: node, markdown: markdown) }
                        }
                    }
                }
            }
        } else if case let .table(rows) = node {
            MarkdownTable(rows: rows, markdown: markdown)
        } else {
            Divider()
        }
    }

    @ViewBuilder
    private func marker(start: Int?, index: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : markdown.secondary)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if let start {
            Text("\(start + index).")
                .font(.system(size: markdown.size).monospacedDigit())
                .foregroundStyle(markdown.secondary)
                .frame(minWidth: 22, alignment: .trailing)
        } else {
            Text(verbatim: "•")
                .font(.system(size: markdown.size))
                .foregroundStyle(markdown.secondary)
                .frame(minWidth: 22)
                .accessibilityHidden(true)
        }
    }
}

struct MarkdownTable: View {
    let rows: [[AttributedString]]
    let markdown: MarkdownRenderStyle

    var body: some View {
        Group {
            if case .preview = markdown.source {
                grid
            } else {
                ScrollView(.horizontal) { grid }
                    .scrollIndicators(.hidden)
            }
        }
        .background(markdown.foreground.opacity(0.05), in: .rect(cornerRadius: 10))
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            ForEach(rows.enumerated(), id: \.offset) { index, row in
                GridRow {
                    ForEach(row.enumerated(), id: \.offset) { _, cell in
                        Text(markdown.prose(cell))
                            .bold(index == 0)
                    }
                }
                if index < rows.count - 1 { Divider() }
            }
        }
        .font(.system(size: markdown.size - 1))
        .foregroundStyle(markdown.foreground)
        .padding(12)
    }
}

struct MarkdownFrontmatterView: View {
    let content: MarkdownFrontmatter.Content
    let markdown: MarkdownRenderStyle

    var body: some View {
        switch content {
        case let .entries(entries) where entries.isEmpty:
            EmptyView()

        case let .entries(entries):
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(entries.enumerated(), id: \.offset) { _, entry in
                    GridRow {
                        Text(entry.key)
                            .foregroundStyle(markdown.secondary)
                        Text(entry.value)
                            .font(entry.isNested ? Font(markdown.style.font) : nil)
                            .foregroundStyle(markdown.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(size: markdown.size - 1))
            .padding(12)
            .background(markdown.foreground.opacity(0.05), in: .rect(cornerRadius: 10))

        case let .raw(text):
            Text(text)
                .font(Font(markdown.style.font))
                .foregroundStyle(markdown.foreground)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(markdown.foreground.opacity(0.05), in: .rect(cornerRadius: 10))
        }
    }
}

struct MarkdownCodeBlock: View {
    let language: String
    let text: String
    let markdown: MarkdownRenderStyle

    @State private var highlighted: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(markdown.secondary)
            }
            if case .preview = markdown.source {
                code.fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal) { code.fixedSize() }
                    .scrollIndicators(.automatic)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: markdown.style.foreground).opacity(0.06), in: .rect(cornerRadius: 10))
        .task(id: [text, language]) {
            guard !language.isEmpty else { return }

            let spans = await Task.detached { CodeHighlighter.spans(in: text, language: language) }.value
            let colored = NSMutableAttributedString(string: text)
            for span in spans where NSMaxRange(span.range) <= colored.length {
                colored.addAttribute(.foregroundColor, value: markdown.style.color(forCapture: span.capture), range: span.range)
            }
            highlighted = try? AttributedString(colored, including: \.appKit)
        }
    }

    private var code: some View {
        Text(highlighted ?? AttributedString(text))
            .font(Font(markdown.style.font))
            .foregroundStyle(Color(nsColor: markdown.style.foreground))
    }
}

struct MarkdownImageView: View {
    let image: MarkdownImage
    let markdown: MarkdownRenderStyle

    @State private var loaded: NSImage?

    var body: some View {
        if let loaded {
            Image(nsImage: loaded)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: loaded.size.width, alignment: .leading)
                .accessibilityLabel(image.alt)
                .task(id: image.source) { await load() }
        } else {
            Label(image.alt.isEmpty ? "Image" : image.alt, systemImage: "photo")
                .font(.system(size: markdown.size))
                .foregroundStyle(markdown.secondary)
                .task(id: image.source) { await load() }
        }
    }

    private func load() async {
        guard let url = markdown.localURL(for: image.source) else { return }

        let data = await Task.detached { try? Data(contentsOf: url) }.value
        loaded = data.flatMap { NSImage(data: $0) }
    }
}
