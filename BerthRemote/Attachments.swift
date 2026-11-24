import SwiftUI
import UIKit

struct Attachment: Identifiable, Equatable {
    let id = UUID().uuidString
    let name: String
    let thumbnail: Data?
    var number: Int?

    nonisolated static func prepared(_ data: Data, name: String, isImage: Bool) -> (attachment: Self, data: Data)? {
        guard isImage else {
            guard data.count <= RemoteUpload.maxBytes else { return nil }

            return (Self(name: name, thumbnail: nil), data)
        }
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }

        let fit = { (side: CGFloat) in
            let scale = min(1, side / max(image.size.width, image.size.height))
            return CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        }
        guard let jpeg = image.preparingThumbnail(of: fit(2048))?.jpegData(compressionQuality: 0.8), jpeg.count <= RemoteUpload.maxBytes else { return nil }

        let base = URL(filePath: name).deletingPathExtension().lastPathComponent
        return (Self(name: "\(base.isEmpty ? "Photo" : base).jpg", thumbnail: image.preparingThumbnail(of: fit(240))?.jpegData(compressionQuality: 0.7)), jpeg)
    }
}

struct AttachmentTile: View {
    let attachment: Attachment
    let state: RemoteClient.UploadState?
    let remove: () -> Void

    @State private var isViewing = false

    var body: some View {
        let status = switch state {
        case .done: ""
        case let .failed(message): message
        case .uploading, nil: String(localized: "Uploading")
        }
        let isUploading = state == nil || state == .uploading

        Group {
            if let image = attachment.thumbnail.flatMap(UIImage.init(data:)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "doc.fill")
                        .font(.subheadline)
                        .accessibilityHidden(true)
                    Text(attachment.name)
                        .font(.caption2)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.secondary)
                .background(.fill.quaternary)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(.rect(cornerRadius: ComposerLayout.tileRadius))
        .overlay(alignment: .bottomLeading) {
            if let number = attachment.number {
                PromptImageTag(number: number)
                    .padding(4)
            }
        }
        .opacity(isUploading ? 0.45 : 1)
        .overlay {
            if isUploading {
                ProgressView()
            } else if case .failed = state {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachment.name)
        .accessibilityValue(status)
        .overlay {
            if attachment.thumbnail != nil {
                Button { isViewing = true } label: { Color.clear.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(attachment.name)")
            }
        }
        .fullScreenCover(isPresented: $isViewing) {
            let item = ViewerImage(id: attachment.id, data: attachment.thumbnail)
            ImageViewer(images: [item], start: item)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: .circle)
                    .background(.background, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
            .offset(x: 16, y: -16)
        }
    }
}
