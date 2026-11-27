import AppKit
import AVFoundation
import BerthCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

enum PromptMentions {
    @MainActor private static let cache = NSCache<NSString, Result>()
    static let linkScheme = "berth-mention"

    final class Result {
        let text: String
        let occurrences: [FileMentions.Occurrence]
        let thumbnails: [ConversationMentionCard.Thumbnail]

        init(text: String, occurrences: [FileMentions.Occurrence]) {
            self.text = text
            self.occurrences = occurrences
            var seen = Set<String>()
            thumbnails = occurrences.compactMap { occurrence in
                let mention = occurrence.mention
                guard mention.exists, seen.insert(mention.path).inserted else { return nil }

                return ConversationMentionCard.Thumbnail(mention: mention)
            }
        }
    }

    @MainActor
    static func resolve(_ text: String, folder: String) -> Result {
        let key = "\(folder)\u{0}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let occurrences = text.contains("@") ? text.split(separator: ConversationPrompt.fence).flatMap { prose in
            PromptTextPart.split(prose).flatMap { part -> [FileMentions.Occurrence] in
                guard case let .text(value) = part else { return [] }

                return FileMentions.extract(from: value, folder: folder) { FileManager.default.fileExists(atPath: $0) }.occurrences
            }
        } : []
        let result = Result(text: text, occurrences: occurrences)
        cache.setObject(result, forKey: key)
        return result
    }
}

struct ConversationMentionTag: View {
    let mention: FileMention
    let scale: CGFloat
    let foreground: Color

    private var font: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1, options: [:]).pointSize * scale, weight: .medium)
    }

    var body: some View {
        HStack(spacing: 3 * scale) {
            Group {
                if mention.exists {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: mention.path)).resizable()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "questionmark.circle").resizable()
                        .accessibilityHidden(true)
                }
            }
            .scaledToFit()
            .frame(width: 13 * scale, height: 13 * scale)
            Text(verbatim: mention.name)
                .font(Font(font))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 5 * scale)
        .padding(.vertical, 2 * scale)
        .background(foreground.opacity(0.1), in: .capsule)
        .opacity(mention.exists ? 1 : 0.55)
    }

    var baselineOffset: CGFloat {
        font.descender - 2 * scale
    }

    @MainActor
    func image(displayScale: CGFloat, colorScheme: ColorScheme) -> NSImage? {
        let key = "\(mention.path)@\(mention.exists)@\(scale)@\(displayScale)@\(foreground)@\(colorScheme)" as NSString
        if let cached = Self.images.object(forKey: key) { return cached }

        let renderer = ImageRenderer(content: environment(\.colorScheme, colorScheme))
        renderer.proposedSize = ProposedViewSize(width: 240 * scale, height: nil)
        renderer.scale = displayScale
        guard let image = renderer.nsImage else { return nil }

        Self.images.setObject(image, forKey: key)
        return image
    }

    @MainActor private static let images = NSCache<NSString, NSImage>()
}

private struct MentionPreview {
    let image: NSImage
    let duration: Duration?
}

struct ConversationMentionCard: View {
    struct Thumbnail: Identifiable {
        let mention: FileMention
        let isVideo: Bool

        var id: String { mention.path }

        init?(mention: FileMention) {
            let url = URL(filePath: mention.path)
            guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }

            let isVideo = type.conforms(to: .movie) || type.conforms(to: .video)
            guard isVideo || type.conforms(to: .image) else { return nil }

            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: mention.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }

            self.mention = mention
            self.isVideo = isVideo
        }
    }

    let thumbnail: Thumbnail

    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.displayScale) private var displayScale
    @State private var preview: MentionPreview?

    private static let cache = NSCache<NSString, NSImage>()
    private static let durations = NSCache<NSString, NSNumber>()

    var body: some View {
        let mention = thumbnail.mention
        let url = URL(filePath: mention.path)
        Button { ConversationImagePreview.shared.showFile(url) } label: { content }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel(mention.name)
            .accessibilityHint("Opens a preview")
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy Path") { copyToPasteboard(mention.path) }
            }
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
                .overlay { if thumbnail.isVideo { playGlyph } }
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
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.foreground.opacity(0.07))
                .frame(width: 160, height: 120)
        }
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
        let path = thumbnail.mention.path
        let key = "\(path)@\(displayScale)" as NSString
        let seconds = Self.durations.object(forKey: key)?.doubleValue
        if let cached = Self.cache.object(forKey: key) { return preview = MentionPreview(image: cached, duration: seconds.map { .seconds($0) }) }

        let url = URL(filePath: path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 120), scale: displayScale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }

        let duration = thumbnail.isVideo ? try? await AVURLAsset(url: url).load(.duration).seconds : nil
        let image = NSImage(cgImage: representation.cgImage, size: NSSize(width: CGFloat(representation.cgImage.width) / displayScale, height: CGFloat(representation.cgImage.height) / displayScale))
        Self.cache.setObject(image, forKey: key)
        if let duration, duration.isFinite { Self.durations.setObject(NSNumber(value: duration), forKey: key) }
        preview = MentionPreview(image: image, duration: duration?.isFinite == true ? duration.map { .seconds($0) } : nil)
    }
}
