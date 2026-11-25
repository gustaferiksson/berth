#if DEBUG
import BerthCore
import Foundation

extension Snapshot {
    static func showFiles(store: Store, review: ReviewModel) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "snapshotFiles"), let session = store.sessionTab else { return }

        store.showReviewPane(.files)
        let files = store.filesModel(for: session)
        files.attach(root: review.changes?.root ?? review.folder)
        files.expanded = Set((defaults.string(forKey: "snapshotFilesExpand") ?? "").split(separator: ";").map(String.init))
        files.reload()
        try? await Task.sleep(for: .seconds(1))
        if let path = defaults.string(forKey: "snapshotFilesOpen") {
            files.reveal(path)
            store.openFile(path, in: files, review: review)
            await review.loadSelectedContents()
        }
        if let filter = defaults.string(forKey: "snapshotFilesFilter") { files.filter = filter }
        try? await Task.sleep(for: .seconds(1))
        print("files pane \(store.shownPane.map(\.rawValue) ?? "-"), rows \(files.rows.map { String(repeating: "  ", count: $0.depth) + $0.entry.name + ($0.entry.isFolder ? "/" : "") }), matches \(files.matches), selected \(files.selected ?? "-")")
    }
}
#endif
