import SwiftUI

struct TranscriptSearchSection: View {
    let query: String
    let open: (RemoteSearchHit) -> Void

    @Environment(RemoteClient.self) private var client

    var body: some View {
        let search = client.transcriptSearch.flatMap { $0.query == query ? $0 : nil }

        Section("Transcripts") {
            ForEach(search?.hits ?? []) { hit in
                Button { open(hit) } label: {
                    TranscriptHitView(hit: hit)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the session")
            }
            if search?.isIndexing != false {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(search == nil ? "Searching…" : "Indexing transcripts…")
                        .foregroundStyle(.secondary)
                }
            } else if search?.hits.isEmpty == true {
                Text("No matching transcripts")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            client.send(.search(query: query))
        }
    }
}

private struct TranscriptHitView: View {
    let hit: RemoteSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(hit.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(hit.lastActivity, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Text(URL(filePath: hit.folder).lastPathComponent)
                .font(.footnote)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(hit.snippets, id: \.self) { snippet in
                Text(highlighted(snippet))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func highlighted(_ snippet: RemoteSnippet) -> AttributedString {
        let units = Array(snippet.text.utf16)
        var result = AttributedString()
        var cursor = 0
        for range in snippet.highlights where range.lowerBound >= cursor && range.upperBound <= units.count {
            var match = AttributedString(String(decoding: units[range], as: UTF16.self))
            match.inlinePresentationIntent = .stronglyEmphasized
            match.foregroundColor = .primary
            result += AttributedString(String(decoding: units[cursor..<range.lowerBound], as: UTF16.self)) + match
            cursor = range.upperBound
        }
        return result + AttributedString(String(decoding: units[cursor...], as: UTF16.self))
    }
}
