import BerthCore
import SwiftUI
import UniformTypeIdentifiers

extension ReviewDocument {
    var isImage: Bool { UTType(filenameExtension: (path as NSString).pathExtension)?.conforms(to: .image) == true }
}

struct FilesImageView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
                    .accessibilityLabel(url.lastPathComponent)
            } else {
                ContentUnavailableView("Can’t Show Image", systemImage: "photo", description: Text(url.lastPathComponent))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}
