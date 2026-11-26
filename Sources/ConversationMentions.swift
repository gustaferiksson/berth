import AppKit
import AVFoundation
import BerthCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

enum PromptMentions {
    @MainActor private static let cache = NSCache<NSString, Result>()

    final class Result {
        let text: String
        let mentions: [FileMention]

        init(text: String, mentions: [FileMention]) {
            self.text = text
            self.mentions = mentions
        }
    }

    @MainActor
    static func resolve(_ text: String, folder: String) -> Result {
        let key = "\(folder)\u{0}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let extracted = text.contains("<pasted_content") ? (text: text, mentions: []) : FileMentions.extract(from: text, folder: folder) { FileManager.default.fileExists(atPath: $0) }
        let result = Result(text: extracted.text, mentions: extracted.mentions)
        cache.setObject(result, forKey: key)
        return result
    }
}

private struct MentionPreview {
    let image: NSImage
    let duration: Duration?
}

struct ConversationMentionCard: View {
    let mention: FileMention

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var preview: MentionPreview?

    private static let cache = NSCache<NSString, NSImage>()
    private static let durations = NSCache<NSString, NSNumber>()

    private var type: UTType? { UTType(filenameExtension: URL(filePath: mention.path).pathExtension) }

    private var isVideo: Bool { type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true }

    private var hasThumbnail: Bool { mention.exists && (isVideo || type?.conforms(to: .image) == true) }

    var body: some View {
        Group {
            if mention.exists {
                Button { ConversationImagePreview.shared.showFile(URL(filePath: mention.path)) } label: { content }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityHint("Opens a preview")
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: mention.path)]) }
                        Button("Copy Path") { copyToPasteboard(mention.path) }
                    }
            } else {
                content
                    .opacity(0.55)
                    .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel(mention.exists ? mention.name : "\(mention.name), missing")
        .task(id: "\(mention.path)@\(displayScale)") { await loadPreview() }
    }

    @ViewBuilder private var content: some View {
        if let preview {
            let size = preview.image.size
            let scale = min(240 / size.width, 120 / size.height)
            Image(nsImage: preview.image)
                .resizable()
                .accessibilityHidden(true)
                .frame(width: size.width * scale, height: size.height * scale)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .overlay { if isVideo { playGlyph } }
                .overlay(alignment: .bottomTrailing) {
                    if let duration = preview.duration {
                        Text(duration.formatted(.time(pattern: .minuteSecond)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: .capsule)
                            .padding(4)
                    }
                }
        } else if hasThumbnail {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.foreground.opacity(0.07))
                .frame(width: 160, height: 120)
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: mention.path))
                .resizable()
                .accessibilityHidden(true)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: mention.name)
                    .font(theme.conversationFont(-1))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: mention.exists ? mention.folder : "Missing")
                    .font(theme.conversationFont(-3))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 240, alignment: .leading)
        .background(theme.foreground.opacity(0.07), in: .rect(cornerRadius: 8, style: .continuous))
    }

    private var playGlyph: some View {
        Image(systemName: "play.fill")
            .font(.body)
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(.black.opacity(0.5), in: .circle)
            .accessibilityHidden(true)
    }

    private func loadPreview() async {
        guard hasThumbnail else { return }

        let key = "\(mention.path)@\(displayScale)" as NSString
        let seconds = Self.durations.object(forKey: key)?.doubleValue
        if let cached = Self.cache.object(forKey: key) { return preview = MentionPreview(image: cached, duration: seconds.map { .seconds($0) }) }

        let url = URL(filePath: mention.path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 120), scale: displayScale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }

        let duration = isVideo ? try? await AVURLAsset(url: url).load(.duration).seconds : nil
        let image = NSImage(cgImage: representation.cgImage, size: NSSize(width: CGFloat(representation.cgImage.width) / displayScale, height: CGFloat(representation.cgImage.height) / displayScale))
        Self.cache.setObject(image, forKey: key)
        if let duration, duration.isFinite { Self.durations.setObject(NSNumber(value: duration), forKey: key) }
        preview = MentionPreview(image: image, duration: duration?.isFinite == true ? duration.map { .seconds($0) } : nil)
    }
}
