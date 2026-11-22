import SwiftUI
import UIKit

struct Attachment: Identifiable, Equatable {
    let id = UUID().uuidString
    let name: String
    let thumbnail: Data?

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
    let size: Double
    let radius: Double
    let remove: () -> Void

    var body: some View {
        Group {
            if let image = attachment.thumbnail.flatMap(UIImage.init(data:)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc.fill")
                    .accessibilityHidden(true)
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.fill.quaternary)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if case .failed = state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(.background, in: .circle)
            } else if state != .done {
                ProgressView()
                    .padding(6)
                    .background(.background, in: .circle)
            }
        }
        .clipShape(.rect(cornerRadius: radius))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.background)
                    .frame(width: 22, height: 22)
                    .background(.primary, in: .circle)
                    .padding(4)
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.name)
        .accessibilityValue(state == .done ? "" : state.map { if case let .failed(message) = $0 { message } else { "Uploading" } } ?? "Uploading")
    }
}
