import AppKit
import BerthCore
import SwiftUI
import WebKit

@Observable
final class ReviewPreviewModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Pick: Equatable {
        let selector: String
        let html: String
        let imagePath: String
    }

    var address = ""
    var ports: [Int] = []
    var isPicking = false
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var pick: Pick?
    var pickText = ""
    var blocked: URL?
    var notice: String?
    @ObservationIgnored private var rulesAreInstalled = false
    @ObservationIgnored lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let world = WKContentWorld.world(name: "berth-picker")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.pickerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        configuration.userContentController.add(PickHandler(model: self), contentWorld: world, name: "berthPick")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()

    private static let allowedPatterns = ["localhost", #"127\.0\.0\.1"#, #"\[::1\]"#].flatMap { host in [":", "/", "$"].map { "^https?://\(host)\($0)" } } + ["^data:", "^blob:", "^about:"]

    private static let pickerScript = #"""
    (() => {
      let on = false, box = null, last = null;
      const selectorOf = (element) => {
        const parts = [];
        for (let e = element; e && e.nodeType === 1 && e !== document.documentElement; e = e.parentElement) {
          if (e.id) { parts.unshift('#' + CSS.escape(e.id)); break; }
          let part = e.tagName.toLowerCase();
          const same = e.parentElement ? [...e.parentElement.children].filter((c) => c.tagName === e.tagName) : [];
          if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(e) + 1) + ')';
          parts.unshift(part);
        }
        return parts.join(' > ');
      };
      const hide = () => { if (box) box.style.display = 'none'; };
      const over = (event) => {
        if (!on) return;
        last = event.target;
        const r = last.getBoundingClientRect();
        Object.assign(box.style, { display: 'block', left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
      };
      const click = (event) => {
        if (!on) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const r = event.target.getBoundingClientRect();
        set(false);
        webkit.messageHandlers.berthPick.postMessage({ selector: selectorOf(event.target), html: event.target.outerHTML.slice(0, 2000), x: r.left, y: r.top, width: r.width, height: r.height });
      };
      const set = (value) => {
        on = value;
        if (!box) {
          box = document.createElement('div');
          Object.assign(box.style, { position: 'fixed', zIndex: 2147483647, pointerEvents: 'none', display: 'none', border: '2px solid #3b82f6', background: 'rgba(59,130,246,0.15)', boxSizing: 'border-box' });
          document.documentElement.appendChild(box);
        }
        document.documentElement.style.cursor = value ? 'crosshair' : '';
        if (!value) hide();
      };
      document.addEventListener('mouseover', over, true);
      document.addEventListener('click', click, true);
      window.berthSetPicking = set;
    })();
    """#

    private static var uploads: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "Berth").appending(path: "PreviewPicks")
    }

    func load(_ text: String) async {
        guard let url = LoopbackURL.parse(text) else {
            notice = "Preview only opens localhost, 127.0.0.1 and [::1]."
            return
        }

        await installRules()
        guard rulesAreInstalled else {
            notice = "Couldn’t restrict the preview to loopback, so nothing was loaded."
            return
        }

        notice = nil
        blocked = nil
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func setPicking(_ value: Bool) async {
        isPicking = value
        _ = try? await webView.evaluateJavaScript("window.berthSetPicking && window.berthSetPicking(\(value))", contentWorld: WKContentWorld.world(name: "berth-picker"))
    }

    func refreshPorts(under root: Int32?) async {
        guard let root else { return }

        let found = await Task.detached { ProcessAncestry.listeningPorts(under: root) }.value
        if found != ports { ports = found }
        if address.isEmpty, webView.url == nil, let first = found.first { await load("localhost:\(first)") }
    }

    func addPick(to model: ReviewModel) {
        guard let pick, let url = webView.url else { return }

        model.comments.append(ReviewComment(id: UUID().uuidString, path: url.absoluteString, line: 0, endLine: 0, text: pickText, snippet: "", compare: nil, element: .init(url: url.absoluteString, selector: pick.selector, html: pick.html, imagePath: pick.imagePath)))
        self.pick = nil
        pickText = ""
    }

    private func installRules() async {
        guard !rulesAreInstalled else { return }

        let rules = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]] + Self.allowedPatterns.map { ["trigger": ["url-filter": $0], "action": ["type": "ignore-previous-rules"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8),
              let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "berth-loopback", encodedContentRuleList: json) else { return }

        webView.configuration.userContentController.add(list)
        rulesAreInstalled = true
    }

    fileprivate func receive(_ body: [String: Any]) async {
        guard let selector = body["selector"] as? String, let html = body["html"] as? String,
              let x = body["x"] as? Double, let y = body["y"] as? Double, let width = body["width"] as? Double, let height = body["height"] as? Double,
              width > 0, height > 0 else { return }

        isPicking = false
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: x, y: y, width: width, height: height)
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let png = NSBitmapImageRep(data: image.tiffRepresentation ?? Data())?.representation(using: .png, properties: [:]) else {
            notice = "Couldn’t capture the element."
            return
        }

        let file = Self.uploads.appending(path: "\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: Self.uploads, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch {
            notice = "Couldn’t save the screenshot: \(error.localizedDescription)"
            return
        }

        pick = Pick(selector: String(selector.prefix(500)), html: String(html.prefix(2000)), imagePath: file.path)
    }

    private func sync() {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url, LoopbackURL.allows(url) { address = url.absoluteString }
    }

    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, LoopbackURL.allows(url) || url.scheme == "about" else {
            blocked = navigationAction.request.url
            return .cancel
        }

        return .allow
    }

    func webView(_: WKWebView, didStartProvisionalNavigation _: WKNavigation?) { sync() }
    func webView(_: WKWebView, didCommit _: WKNavigation?) { sync() }
    func webView(_: WKWebView, didFinish _: WKNavigation?) { sync() }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError error: any Error) {
        sync()
        notice = error.localizedDescription
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: any Error) {
        sync()
        notice = (error as NSError).code == NSURLErrorCancelled ? notice : error.localizedDescription
    }

    func webView(_ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, LoopbackURL.allows(url) else {
            blocked = navigationAction.request.url
            return nil
        }

        webView.load(navigationAction.request)
        return nil
    }
}

private final class PickHandler: NSObject, WKScriptMessageHandler {
    weak var model: ReviewPreviewModel?

    init(model: ReviewPreviewModel) {
        self.model = model
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let model else { return }

        Task { await model.receive(body) }
    }
}

private struct PreviewWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context _: Context) -> WKWebView { webView }

    func updateNSView(_: WKWebView, context _: Context) {}
}

struct ReviewPreviewView: View {
    let model: ReviewModel
    let rootPID: Int32?
    @Environment(\.ghosttyTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let preview = model.preview
        VStack(spacing: 0) {
            toolbar(preview)
            if let blocked = preview.blocked {
                HStack {
                    Text("Blocked \(blocked.host() ?? blocked.absoluteString)")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Open in Browser") { openURL(blocked) }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            if let notice = preview.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(theme.needsYou)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            if let pick = preview.pick {
                pickBar(preview, pick)
            }
            if preview.webView.url == nil {
                ContentUnavailableView("No Dev Server", systemImage: "globe", description: Text("Start one in this session, or type a localhost address."))
            } else {
                PreviewWebView(webView: preview.webView)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: rootPID) {
            while !Task.isCancelled {
                await preview.refreshPorts(under: rootPID)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func toolbar(_ preview: ReviewPreviewModel) -> some View {
        @Bindable var preview = preview
        return HStack(spacing: 6) {
            GlassCapsule {
                Button("Back", systemImage: "chevron.left") { preview.webView.goBack() }
                    .disabled(!preview.canGoBack)
                Button("Forward", systemImage: "chevron.right") { preview.webView.goForward() }
                    .disabled(!preview.canGoForward)
                Button(preview.isLoading ? "Stop" : "Reload", systemImage: preview.isLoading ? "xmark" : "arrow.clockwise") {
                    if preview.isLoading { preview.webView.stopLoading() } else { preview.webView.reload() }
                }
            }
            TextField("localhost:3000", text: $preview.address)
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .glassEffect(.regular, in: .capsule)
                .onSubmit { Task { await preview.load(preview.address) } }
            if !preview.ports.isEmpty {
                Menu("Detected Servers", systemImage: "network") {
                    ForEach(preview.ports, id: \.self) { port in
                        Button("localhost:\(port)") { Task { await preview.load("localhost:\(port)") } }
                    }
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            GlassCapsule {
                Button("Pick Element", systemImage: preview.isPicking ? "scope" : "cursorarrow.rays") {
                    Task { await preview.setPicking(!preview.isPicking) }
                }
                .foregroundStyle(preview.isPicking ? Color.accentColor : theme.secondary)
                .disabled(preview.webView.url == nil)
            }
        }
        .padding(8)
    }

    private func pickBar(_ preview: ReviewPreviewModel, _ pick: ReviewPreviewModel.Pick) -> some View {
        @Bindable var preview = preview
        return VStack(alignment: .leading, spacing: 6) {
            Text(pick.selector)
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondary)
                .lineLimit(2)
            TextField("Comment on this element", text: $preview.pickText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit { preview.addPick(to: model) }
            HStack {
                Button("Cancel") { preview.pick = nil }
                Spacer()
                Button("Add Comment") { preview.addPick(to: model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.pickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
    }
}
