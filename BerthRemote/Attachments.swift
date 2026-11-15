import SwiftUI
import UIKit

struct Attachment: Identifiable, Equatable {
    let id = UUID().uuidString
    let name: String
    let thumbnail: Data?

    nonisolated static func prepared(_ data: Data, name: String, isImage: Bool) -> (attachment: Attachment, data: Data)? {
        guard isImage else {
            guard data.count <= RemoteUpload.maxBytes else { return nil }
            return (Attachment(name: name, thumbnail: nil), data)
        }

        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let fit = { (side: CGFloat) in
            let scale = min(1, side / max(image.size.width, image.size.height))
            return CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        }
        guard let jpeg = image.preparingThumbnail(of: fit(2048))?.jpegData(compressionQuality: 0.8), jpeg.count <= RemoteUpload.maxBytes else { return nil }
        let base = URL(filePath: name).deletingPathExtension().lastPathComponent
        return (Attachment(name: "\(base.isEmpty ? "Photo" : base).jpg", thumbnail: image.preparingThumbnail(of: fit(240))?.jpegData(compressionQuality: 0.7)), jpeg)
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    let state: RemoteClient.UploadState?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let image = attachment.thumbnail.flatMap(UIImage.init(data:)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .lineLimit(1)
                if case let .failed(message) = state {
                    Text(message)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if state != .done {
                    Text("Uploading…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .frame(maxWidth: 140, alignment: .leading)
            Button("Remove \(attachment.name)", systemImage: "xmark.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(6)
        .padding(.trailing, 4)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }
}
