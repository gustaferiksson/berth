import SwiftUI
import UIKit

struct ToolImageRow: View {
    let refs: [RemoteImageRef]

    @State private var selection: RemoteImageRef?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(refs.enumerated(), id: \.element.id) { index, ref in
                    Button { selection = ref } label: {
                        ImageThumbnail(ref: ref)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(refs.count == 1 ? "Image" : "Image \(index + 1) of \(refs.count)")
                    .accessibilityHint("Opens the image full screen")
                }
            }
        }
        .scrollIndicators(.hidden)
        .fullScreenCover(item: $selection) { ImageViewer(refs: refs, start: $0) }
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

private struct ImageViewer: View {
    let refs: [RemoteImageRef]

    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var current: RemoteImageRef

    init(refs: [RemoteImageRef], start: RemoteImageRef) {
        self.refs = refs
        _current = State(initialValue: start)
    }

    var body: some View {
        let full = image(for: current, variant: .full)

        NavigationStack {
            TabView(selection: $current) {
                ForEach(refs) { ref in
                    ZoomableImage(image: image(for: ref, variant: .full) ?? image(for: ref, variant: .thumbnail))
                        .overlay { if image(for: ref, variant: .full) == nil { ProgressView() } }
                        .tag(ref)
                        .task { client.loadImage(ref.id, variant: .full) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: refs.count > 1 ? .automatic : .never))
            .background(Color(.systemBackground))
            .ignoresSafeArea()
            .navigationBarTitleDisplayMode(.inline)
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

    private func image(for ref: RemoteImageRef, variant: RemoteImageVariant) -> UIImage? {
        guard case let .loaded(data)? = client.images[.init(id: ref.id, variant: variant)] else { return nil }

        return UIImage(data: data)
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

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
