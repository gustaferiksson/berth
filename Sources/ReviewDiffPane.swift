import BerthCore
import SwiftUI

struct ReviewDiffPane: View {
    let path: String
    let contents: ReviewContents
    @Binding var draft: String?
    let onComment: (_ line: Int, _ endLine: Int, _ text: String, _ snippet: String) -> Void
    let onSave: (_ text: String) -> Void
    @Environment(\.ghosttyTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            side(contents.original)
            Hairline(axis: .vertical)
            side(draft.map(ReviewText.text) ?? contents.modified)
        }
    }

    private func side(_ text: ReviewText?) -> some View {
        let shown: String = if case let .text(text)? = text {
            text
        } else if case let .tooLarge(bytes)? = text {
            "Too large to show (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
        } else {
            text == .binary ? "Binary file" : ""
        }
        return ScrollView([.vertical, .horizontal]) {
            Text(shown)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.foreground)
                .textSelection(.enabled)
                .fixedSize()
                .padding(8)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
