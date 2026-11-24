import SwiftUI
import UIKit

struct ViewerImage: Identifiable, Hashable {
    let id: String
    var data: Data?
    var ref: RemoteImageRef?
}

struct ToolImageRow: View {
    let refs: [RemoteImageRef]

    @State private var selection: ViewerImage?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(refs.enumerated(), id: \.element.id) { index, ref in
                    Button { selection = ViewerImage(id: ref.id, ref: ref) } label: {
                        ImageThumbnail(ref: ref)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(refs.count == 1 ? "Image" : "Image \(index + 1) of \(refs.count)")
                    .accessibilityHint("Opens the image full screen")
                }
            }
        }
        .scrollIndicators(.hidden)
        .fullScreenCover(item: $selection) { ImageViewer(images: refs.map { ViewerImage(id: $0.id, ref: $0) }, start: $0) }
    }
}

private struct ImageThumbnail: View {
    let ref: RemoteImageRef

    @Environment(RemoteClient.self) private var client

    var body: some View {
        let load = client.images[.init(id: ref.id, variant: .thumbnail)]

        Group {
            if case let .loaded(data) = load, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: load == .failed ? "photo.badge.exclamationmark" : "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .overlay { if load == .loading { ProgressView() } }
            }
        }
        .frame(width: 160, height: 120)
        .background(.fill.tertiary)
        .clipShape(.rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 14))
        .task { client.loadImage(ref.id, variant: .thumbnail) }
    }
}

struct ImageViewer: View {
    let images: [ViewerImage]

    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var current: ViewerImage
    @State private var isZoomed = false

    init(images: [ViewerImage], start: ViewerImage) {
        self.images = images
        _current = State(initialValue: start)
    }

    var body: some View {
        let full = image(for: current, variant: .full)
        let dismissDrag = DragGesture().onEnded { drag in
            guard !isZoomed, drag.translation.height > 120, drag.translation.height > 2 * abs(drag.translation.width) else { return }

            dismiss()
        }

        NavigationStack {
            TabView(selection: $current) {
                ForEach(images) { item in
                    let isLoadingFull = item.ref != nil && image(for: item, variant: .full) == nil

                    ZoomableImage(image: image(for: item, variant: .full) ?? image(for: item, variant: .thumbnail), isZoomed: $isZoomed)
                        .overlay { if isLoadingFull { ProgressView() } }
                        .tag(item)
                        .task { if let ref = item.ref { client.loadImage(ref.id, variant: .full) } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .background(Color(.systemBackground))
            .ignoresSafeArea()
            .simultaneousGesture(dismissDrag)
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let cgImage = full?.cgImage {
                        let picture = Image(decorative: cgImage, scale: 1)
                        ShareLink(item: picture, preview: SharePreview("Image", image: picture))
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func image(for item: ViewerImage, variant: RemoteImageVariant) -> UIImage? {
        guard let ref = item.ref else { return variant == .full ? item.data.flatMap(UIImage.init(data:)) : nil }
        guard case let .loaded(data)? = client.images[.init(id: ref.id, variant: variant)] else { return nil }

        return UIImage(data: data)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    @Binding var isZoomed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(isZoomed: $isZoomed) }

    func makeUIView(context: Context) -> FittingScrollView {
        let scrollView = FittingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.imageView.contentMode = .scaleAspectFit
        scrollView.imageView.isAccessibilityElement = true
        scrollView.imageView.accessibilityLabel = "Image"
        scrollView.addSubview(scrollView.imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: FittingScrollView, context _: Context) {
        scrollView.imageView.image = image
    }

    final class FittingScrollView: UIScrollView {
        let imageView = UIImageView()

        override func layoutSubviews() {
            super.layoutSubviews()
            guard zoomScale == 1 else { return }

            imageView.frame = bounds
            contentSize = bounds.size
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let isZoomed: Binding<Bool>

        init(isZoomed: Binding<Bool>) { self.isZoomed = isZoomed }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { isZoomed.wrappedValue = scrollView.zoomScale > 1 }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? FittingScrollView)?.imageView }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? FittingScrollView else { return }
            guard scrollView.zoomScale == 1 else { return scrollView.setZoomScale(1, animated: true) }

            let point = gesture.location(in: scrollView.imageView)
            let size = CGSize(width: scrollView.bounds.width / 3, height: scrollView.bounds.height / 3)
            scrollView.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        }
    }
}
