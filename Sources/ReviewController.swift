import BerthCore
import Foundation
import SwiftUI
import WebKit

final class ReviewController: NSObject, WKNavigationDelegate {
    #if DEBUG
    private static let pageErrorForwarder = """
    for (const level of ["warn", "error"]) {
      const original = console[level]
      console[level] = (...args) => {
        window.webkit.messageHandlers.berth.postMessage({ type: "pageError", text: `console.${level}: ${args.map(String).join(" ")}` })
        original.apply(console, args)
      }
    }
    addEventListener("error", event => window.webkit.messageHandlers.berth.postMessage({ type: "pageError", text: `${event.message} ${event.filename}:${event.lineno}` }))
    addEventListener("unhandledrejection", event => window.webkit.messageHandlers.berth.postMessage({ type: "pageError", text: `unhandled rejection: ${String(event.reason)}` }))
    """
    #endif

    let webView: WKWebView
    var theme: GhosttyTheme? {
        didSet {
            webView.underPageBackgroundColor = theme?.background.map(NSColor.init) ?? .windowBackgroundColor
            if theme != oldValue { send(ThemeMessage(theme: Self.loadedTheme())) }
        }
    }

    private let sessionID: String
    private let folder: String
    private let store: Store
    private var compare = ReviewCompare.allChanges
    private var snapshot: ReviewSnapshot?
    private var allFiles: [String] = []
    private var selectedPath: String?
    private var isReady = false
    private var generation = 0
    private var note: String?
    private var prNumber: Int?
    private var sentTexts: [String: String] = [:]
    private var loadTask: Task<Void, Never>?
    private(set) var dirtyPaths: [String] = []

    init(sessionID: String, folder: String, store: Store) {
        self.sessionID = sessionID
        self.folder = folder
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ReviewSchemeHandler(), forURLScheme: ReviewSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.configuration.userContentController.add(WeakMessageHandler(target: self), name: "berth")
        #if DEBUG
        webView.isInspectable = true
        let setOcclusionDetection = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if Snapshot.output != nil, webView.responds(to: setOcclusionDetection) {
            // WebKit pauses rendering in an occluded window, and the snapshot window sits off screen.
            typealias Setter = @convention(c) (NSView, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: setOcclusionDetection), to: Setter.self)(webView, setOcclusionDetection, false)
        }
        webView.configuration.userContentController.addUserScript(WKUserScript(source: Self.pageErrorForwarder, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
        webView.navigationDelegate = self
        webView.load(URLRequest(url: URL(string: "\(ReviewSchemeHandler.scheme)://app/index.html")!))
    }

    func tearDown() {
        guard store.reviewControllers[sessionID] === self else { return }

        store.reviewControllers[sessionID] = nil
        loadTask?.cancel()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "berth")
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.scheme == ReviewSchemeHandler.scheme ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        dirtyPaths = []
        webView.reload()
    }

    private var session: SessionSummary? {
        (store.activeSessions + store.archivedSessions).first { $0.id == sessionID }
    }

    func receive(_ body: Any) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let message = try? JSONDecoder().decode(Incoming.self, from: data)
        else { return }
        #if DEBUG
        if Snapshot.output != nil { store.probeReview.append("in \(message.type)\(message.type == "pageError" ? ": \(message.text ?? "")" : "")") }
        #endif

        if message.type == "ready" {
            isReady = true
            return load()
        }
        if message.type == "refresh" { return load() }
        if message.type == "selectCompare" {
            let selected: ReviewCompare? = message.compare == "allChanges" ? .allChanges : message.compare == "uncommitted" ? .uncommitted : message.compare == "pr" ? prNumber.map(ReviewCompare.pullRequest) : nil
            guard let selected else { return }
            compare = selected
            return load()
        }
        if message.type == "openFile", let path = message.path {
            selectedPath = path
            return sendFile(path)
        }
        if message.type == "readFile", let path = message.path { return sendFile(path) }
        if message.type == "save", let path = message.path, let text = message.text { return save(text, to: path) }
        if message.type == "dirty", let paths = message.paths {
            dirtyPaths = paths
            return
        }
        if message.type == "commentsChanged", let comments = message.comments {
            store.reviewComments[sessionID] = comments
            return
        }
        if message.type == "sendComments", let comments = message.comments, !comments.isEmpty { return sendComments(comments) }
        if message.type == "definition" || message.type == "references", let id = message.id { send(Reply(id: id)) }
    }

    func load() {
        loadTask?.cancel()
        generation += 1
        let (compare, folder) = (compare, folder)
        loadTask = Task {
            let result = await Task.detached {
                let snapshot = try await ReviewGit.snapshot(compare, in: folder)
                return (snapshot, try await ReviewGit.projectFiles(in: snapshot.root))
            }.result
            let origin = await Task.detached { await ReviewGit.originRepository(in: folder) }.value
            guard !Task.isCancelled else { return }

            let pullRequest = session?.pullRequest
            prNumber = pullRequest?.repository.lowercased() == origin?.lowercased() ? pullRequest?.number : nil

            if case .failure(ReviewGitError.noBase) = result, compare == .allChanges {
                self.compare = .uncommitted
                note = "No base branch found, showing uncommitted changes"
                return load()
            }

            snapshot = try? result.get().0
            allFiles = (try? result.get().1) ?? []
            send(loadMessage())
            if case let .failure(error) = result { send(Notice(message: Self.describe(error))) }
            if let note { send(Notice(message: note)) }
            note = nil
        }
    }

    private static func loadedTheme() -> Load.Theme {
        let values = GhosttyConfig.load().values
        return Load.Theme(
            background: values["background"],
            foreground: values["foreground"],
            selection: values["selection-background"],
            palette: (0..<16).map { values["palette-\($0)"] ?? "" },
            fontFamily: values["font-family"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            fontSize: values["font-size"].flatMap(Double.init)
        )
    }

    private func loadMessage() -> Load {
        Load(
            theme: Self.loadedTheme(),
            compare: compare == .allChanges ? "allChanges" : compare == .uncommitted ? "uncommitted" : "pr",
            prNumber: prNumber,
            base: snapshot?.base ?? "",
            mergeBase: snapshot?.mergeBase ?? "",
            fetchedAt: snapshot?.fetchedAt,
            fetchError: snapshot?.fetchError,
            editable: snapshot?.isEditable ?? false,
            files: snapshot?.files ?? [],
            allFiles: allFiles,
            comments: store.reviewComments[sessionID] ?? [],
            selectedPath: selectedPath
        )
    }

    private func sendFile(_ path: String) {
        guard let snapshot else { return }

        let file = snapshot.files.first { $0.path == path }
        guard file != nil || allFiles.contains(path) else { return }

        let generation = generation
        Task {
            let result = await Task.detached { () async throws -> (original: ReviewText?, modified: ReviewText?) in
                guard let file else { return (nil, try ReviewGit.workingTreeText(path, in: snapshot.root)) }
                let contents = try await ReviewGit.contents(of: file, in: snapshot)
                return (contents.original, contents.modified)
            }.result
            guard generation == self.generation else { return }

            guard case let .success(sides) = result else {
                if case let .failure(error) = result { send(Notice(message: "Couldn’t read \(path): \(Self.describe(error))")) }
                return
            }
            let original: String? = if case let .text(text)? = sides.original { text } else { nil }
            let modified: String? = if case let .text(text)? = sides.modified { text } else { nil }
            let isTooLarge = [sides.original, sides.modified].contains { if case .tooLarge? = $0 { true } else { false } }
            if !dirtyPaths.contains(path) { sentTexts[path] = modified }
            send(FileMessage(
                path: path,
                original: original,
                modified: modified,
                binary: [sides.original, sides.modified].contains(.some(.binary)),
                tooLarge: isTooLarge,
                editable: snapshot.isEditable && file != nil && file?.status != .deleted && modified != nil
            ))
        }
    }

    private func save(_ text: String, to path: String) {
        guard let snapshot, snapshot.isEditable, snapshot.files.contains(where: { $0.path == path && $0.status != .deleted }) else {
            return send(Notice(message: "\(path) is read only here"))
        }

        let expected = sentTexts[path]
        Task {
            let result = await Task.detached { () throws -> Bool in
                guard let expected, (try? ReviewGit.workingTreeText(path, in: snapshot.root)) == .text(expected) else { return false }
                try ReviewGit.save(text, to: path, in: snapshot.root)
                return true
            }.result
            if case let .failure(error) = result { return send(Notice(message: "Couldn’t save \(path): \(Self.describe(error))")) }
            guard case .success(true) = result else { return send(Notice(message: "\(path) changed on disk; reload before saving")) }

            sentTexts[path] = text
            send(Saved(path: path))
        }
    }

    private func sendComments(_ comments: [ReviewComment]) {
        let prompt = ReviewComment.prompt(for: comments, branch: session?.branch ?? "HEAD", base: snapshot?.base ?? "HEAD")
        guard store.liveBySession[sessionID] != nil, let terminal = store.tab(forSession: sessionID)?.terminal, terminal.paste(text: prompt) else {
            return send(Notice(message: "Claude isn’t running in this tab; comments kept"))
        }

        store.reviewComments[sessionID] = nil
        store.reviewSessionID = nil
    }

    private func send(_ message: some Encodable) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard isReady, let data = try? encoder.encode(message) else { return }

        let json = String(decoding: data, as: UTF8.self)
        #if DEBUG
        let summary = (message as? Load).map { "load \($0.compare) base \($0.base) files \($0.files.count) project \($0.allFiles.count) editable \($0.editable) fetchError \($0.fetchError ?? "-")" }
            ?? (message as? FileMessage).map { "file \($0.path) binary \($0.binary) tooLarge \($0.tooLarge) editable \($0.editable)" }
        if Snapshot.output != nil { store.probeReview.append("out \(summary ?? String(json.prefix(200)))") }
        #endif
        webView.evaluateJavaScript("window.berth.receive(\(json))")
    }

    private static func describe(_ error: any Error) -> String {
        if case let ReviewGitError.git(_, message) = error { return message }
        if case let ReviewGitError.fetchFailed(message) = error { return "Fetch failed: \(message)" }
        return String(describing: error)
    }
}

private struct Incoming: Decodable {
    let type: String
    let compare: String?
    let path: String?
    let text: String?
    let comments: [ReviewComment]?
    let paths: [String]?
    let id: Int?
}

private struct Load: Encodable {
    struct Theme: Encodable {
        let background: String?
        let foreground: String?
        let selection: String?
        let palette: [String]
        let fontFamily: String?
        let fontSize: Double?
    }

    var type = "load"
    let theme: Theme
    let compare: String
    let prNumber: Int?
    let base: String
    let mergeBase: String
    let fetchedAt: Date?
    let fetchError: String?
    let editable: Bool
    let files: [ReviewFile]
    let allFiles: [String]
    let comments: [ReviewComment]
    let selectedPath: String?
}

private struct FileMessage: Encodable {
    var type = "file"
    let path: String
    let original: String?
    let modified: String?
    let binary: Bool
    let tooLarge: Bool
    let editable: Bool
}

private struct ThemeMessage: Encodable {
    var type = "theme"
    let theme: Load.Theme
}

private struct Saved: Encodable {
    var type = "saved"
    let path: String
}

private struct Notice: Encodable {
    var type = "error"
    let message: String
}

private struct Reply: Encodable {
    var type = "reply"
    let id: Int
}
