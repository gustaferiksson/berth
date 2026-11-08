import BerthCore
import SwiftUI
import WebKit

struct ReviewView: View {
    let sessionID: String
    let folder: String
    @Environment(Store.self) private var store

    var body: some View {
        if FileManager.default.fileExists(atPath: RepositoryRoot.resolve(folder) + "/.git") {
            ReviewWebView(sessionID: sessionID, folder: folder, store: store, theme: store.theme)
        } else {
            ContentUnavailableView("Not a Git Repository", systemImage: "plus.forwardslash.minus", description: Text("\((folder as NSString).abbreviatingWithTildeInPath) isn’t in a Git repository, so there are no changes to review."))
                .background(store.theme.background ?? .clear)
        }
    }
}

private struct ReviewWebView: NSViewRepresentable {
    let sessionID: String
    let folder: String
    let store: Store
    let theme: GhosttyTheme

    func makeCoordinator() -> ReviewController {
        if let kept = store.reviewControllers[sessionID] {
            kept.load()
            return kept
        }
        let controller = ReviewController(sessionID: sessionID, folder: folder, store: store)
        store.reviewControllers[sessionID] = controller
        return controller
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = context.coordinator.webView
        DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.theme = theme
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: ReviewController) {
        guard coordinator.dirtyPaths.isEmpty else { return }
        coordinator.tearDown()
    }
}

final class ReviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "berth-review"
    private static let contentTypes = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "ttf": "font/ttf",
    ]

    private let folder = Bundle.main.resourceURL?.appending(path: "Review", directoryHint: .isDirectory).resolvingSymlinksInPath()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host() == "app", let folder else { return task.didFailWithError(URLError(.badURL)) }

        let file = folder.appending(path: String(url.path(percentEncoded: false).dropFirst())).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(folder.path + "/"), let data = try? Data(contentsOf: file) else { return task.didFailWithError(URLError(.fileDoesNotExist)) }

        let headers = ["Content-Type": Self.contentTypes[file.pathExtension.lowercased()] ?? "application/octet-stream", "Content-Length": "\(data.count)"]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return task.didFailWithError(URLError(.badServerResponse)) }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: ReviewController?

    init(target: ReviewController) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == ReviewSchemeHandler.scheme else { return }
        target?.receive(message.body)
    }
}
