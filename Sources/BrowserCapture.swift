import AppKit
import WebKit

private enum BrowserCaptureError: LocalizedError {
    case closed, busy, empty, short

    var errorDescription: String? {
        switch self {
        case .closed: "The browser tab closed while loading"
        case .busy: "This browser tab is already taking a screenshot"
        case .empty: "Couldn’t create a browser screenshot"
        case .short: "The full-page screenshot did not extend beyond the viewport"
        }
    }
}

extension BrowserTab {
    func pageText() async throws -> String {
        let view = webView
        await waitForNavigation(in: view)
        guard view === loadedWebView else { throw BrowserCaptureError.closed }

        let limit = 100_000
        let result = try await view.evaluateJavaScript("document.body?.innerText.slice(0, \(2 * limit + 1)) ?? ''", contentWorld: .defaultClient) as? String ?? ""
        let scalars = result.unicodeScalars
        let end = scalars.index(scalars.startIndex, offsetBy: limit, limitedBy: scalars.endIndex) ?? scalars.endIndex
        guard end != scalars.endIndex else { return result }

        return String(scalars[..<end]) + "\n\n[Text truncated at \(limit) characters]"
    }

    func screenshot(fullPage: Bool, fallbackSize: NSSize) async throws -> Data {
        guard !isTakingScreenshot else { throw BrowserCaptureError.busy }

        isTakingScreenshot = true
        defer { isTakingScreenshot = false }

        let view = webView
        let originalFrame = view.frame
        let originalMask = view.autoresizingMask
        let window: NSWindow?
        let host: NSView?
        if view.window == nil {
            let bounds = NSRect(origin: .zero, size: fallbackSize)
            let content = NSView(frame: bounds)
            let offscreen = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            offscreen.contentView = content
            offscreen.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            view.frame = content.bounds
            view.autoresizingMask = []
            content.addSubview(view)
            offscreen.orderFrontRegardless()
            window = offscreen
            host = content
        } else {
            window = nil
            host = nil
        }
        defer {
            if let host, view.superview === host {
                view.removeFromSuperview()
                view.frame = originalFrame
                view.autoresizingMask = originalMask
            }
            window?.orderOut(nil)
        }

        await waitForNavigation(in: view)
        guard view === loadedWebView else { throw BrowserCaptureError.closed }

        let url = view.url
        let metrics = if fullPage {
            try await view.evaluateJavaScript(
                "[Math.max(document.documentElement?.scrollHeight ?? 0, document.body?.scrollHeight ?? 0), window.scrollX, window.scrollY]",
                contentWorld: .defaultClient
            ) as? [Double]
        } else {
            nil as [Double]?
        }
        guard view === loadedWebView else { throw BrowserCaptureError.closed }

        let captureContainer = view.superview
        let captureFrame = view.frame
        let captureMask = view.autoresizingMask
        let containerSize = captureContainer?.bounds.size
        let viewport = captureFrame.isEmpty ? fallbackSize : captureFrame.size
        let height = fullPage ? min(max(metrics?.first ?? 0, viewport.height), 10_000) : viewport.height
        let resizesView = height != viewport.height || captureFrame.isEmpty
        if resizesView {
            view.autoresizingMask = []
            view.setFrameSize(NSSize(width: viewport.width, height: height))
        }

        if metrics?.count == 3 {
            _ = try? await view.evaluateJavaScript("window.scrollTo({left: 0, top: 0, behavior: 'instant'})", contentWorld: .defaultClient)
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        let image = try? await view.takeSnapshot(configuration: configuration)

        if resizesView, view.superview === captureContainer {
            view.autoresizingMask = captureMask
            view.frame = containerSize == captureContainer?.bounds.size ? captureFrame : captureContainer?.bounds ?? captureFrame
        }
        if let metrics, metrics.count == 3, view === loadedWebView, view.url == url {
            _ = try? await view.evaluateJavaScript("window.scrollTo({left: \(metrics[1]), top: \(metrics[2]), behavior: 'instant'})", contentWorld: .defaultClient)
        }
        guard let image else { throw BrowserCaptureError.empty }
        guard height <= viewport.height || image.size.height > viewport.height else { throw BrowserCaptureError.short }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw BrowserCaptureError.empty }

        return png
    }
}
