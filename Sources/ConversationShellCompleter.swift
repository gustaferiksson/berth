import AppKit
import BerthCore
import Observation

@Observable
final class TineStatus {
    static let shared = TineStatus()

    var isUnsupported = false

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: TineClient.defaultSocketPath)
            || NSWorkspace.shared.urlForApplication(withBundleIdentifier: TineClient.bundleIdentifier) != nil
    }
}

@Observable
final class ConversationShellCompleter {
    struct Row: Identifiable {
        let id: Int
        let item: TineCompletion.Item
    }

    static let enabledKey = "conversationShellCompletions"

    private(set) var rows: [Row] = []
    private(set) var selectedID: Int?
    @ObservationIgnored var folder = ""
    @ObservationIgnored weak var field: ComposerTextView?
    @ObservationIgnored private var request: TineRequest?
    @ObservationIgnored private var rowsDraft: String?
    @ObservationIgnored private var dismissedDraft: String?
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let client: TineClient

    init() {
        let override = UserDefaults.standard.string(forKey: "snapshotTineSocket")
        client = override.map { TineClient(socketPath: $0, launch: {}) } ?? TineClient()
    }

    func update(draft: String, caret: Int) {
        guard !isStopped else { return }

        if draft != dismissedDraft { dismissedDraft = nil }
        guard dismissedDraft == nil, let next = TineRequest(draft: draft, caret: caret, cwd: folder) else { return reset() }
        guard next != request else { return }

        request = next
        task?.cancel()
        task = Task { await fetch(next) }
    }

    func reset() {
        task?.cancel()
        request = nil
        rows = []
        selectedID = nil
        isStopped = false
    }

    func dismiss() -> Bool {
        guard !rows.isEmpty else { return false }

        dismissedDraft = request?.draft
        reset()
        return true
    }

    func move(by offset: Int) -> Bool {
        guard !rows.isEmpty else { return false }

        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = rows[(current + offset + rows.count) % rows.count].id
        return true
    }

    var isShowing: Bool { !rows.isEmpty }

    func accept(_ row: Row? = nil) -> Bool {
        guard let row = row ?? rows.first(where: { $0.id == selectedID }) ?? rows.first,
              let field, field.string == rowsDraft else { return false }

        let item = row.item
        field.window?.makeFirstResponder(field)
        field.insertText(item.text, replacementRange: item.replacement)
        field.setSelectedRange(NSRange(location: item.caret, length: 0))
        return true
    }

    private func fetch(_ request: TineRequest) async {
        try? await Task.sleep(for: .milliseconds(40))
        for _ in 0..<8 {
            guard !Task.isCancelled else { return }

            switch try? await client.complete(request) {
            case nil:
                guard !Task.isCancelled else { return }

                isStopped = true
                return show([], for: request)

            case .unsupported:
                TineStatus.shared.isUnsupported = true
                isStopped = true
                return show([], for: request)

            case let .completion(completion)?:
                guard !Task.isCancelled else { return }

                show(completion.items, for: request)
                guard completion.isPending else { return }

                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func show(_ items: [TineCompletion.Item], for request: TineRequest) {
        let next = items.enumerated().map { Row(id: $0.offset, item: $0.element) }
        rowsDraft = request.draft
        guard next.map(\.item) != rows.map(\.item) else { return }

        rows = next
        selectedID = nil
    }
}

extension TineCompletion.Kind {
    var symbol: String {
        switch self {
        case .subcommand: "arrow.turn.down.right"
        case .option: "minus"
        case .arg: "text.cursor"
        case .file: "doc"
        case .folder: "folder"
        case .history: "clock"
        case .special: "sparkles"
        case .mixin: "puzzlepiece"
        case .shortcut: "bolt"
        case .generic: "chevron.right"
        }
    }
}
