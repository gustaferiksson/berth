import BerthCore
import Foundation

struct FileEntry: Hashable, Identifiable {
    let path: String
    let name: String
    let isFolder: Bool
    let isIgnored: Bool

    var id: String { path }
}

struct FileRow: Identifiable {
    let entry: FileEntry
    let depth: Int

    var id: String { entry.path }
}

@Observable
final class FilesModel {
    private(set) var root = ""
    private(set) var entries: [String: [FileEntry]] = [:]
    private(set) var matches: [String] = []
    var expanded: Set<String> = []
    var selected: String?
    var cursor: String?
    var filter = "" {
        didSet { search() }
    }

    var showsIgnored = false {
        didSet { reload() }
    }

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var reloading: Task<Void, Never>?
    @ObservationIgnored private var searching: Task<Void, Never>?
    @ObservationIgnored private var allFiles: [String]?

    var rows: [FileRow] {
        func rows(in folder: String, depth: Int) -> [FileRow] {
            (entries[folder] ?? []).filter { showsIgnored || !$0.isIgnored }.flatMap { entry in
                [FileRow(entry: entry, depth: depth)] + (entry.isFolder && expanded.contains(entry.path) ? rows(in: entry.path, depth: depth + 1) : [])
            }
        }

        return rows(in: "", depth: 0)
    }

    func attach(root: String) {
        guard root != self.root else { return }

        self.root = root
        entries = [:]
        allFiles = nil
        watcher = FileWatcher(paths: [root], latency: 0.5) { [weak self] paths in
            guard paths.contains(where: { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }) else { return }

            self?.reload()
        }
        reload()
    }

    func toggle(_ folder: String) {
        if expanded.remove(folder) == nil { expanded.insert(folder) }
        reload()
    }

    func reveal(_ path: String) {
        let folders = path.split(separator: "/").dropLast().reduce(into: [String]()) { $0.append(($0.last.map { $0 + "/" } ?? "") + $1) }
        guard !expanded.isSuperset(of: folders) else { return }

        expanded.formUnion(folders)
        reload()
    }

    func reload() {
        guard !root.isEmpty else { return }

        let root = root
        let folders = [""] + expanded.sorted()
        reloading?.cancel()
        reloading = Task {
            var listed: [String: [FileEntry]] = [:]
            for folder in folders { listed[folder] = await Self.list(folder, in: root) }
            guard !Task.isCancelled else { return }

            entries = listed
            allFiles = nil
            search()
        }
    }

    private func search() {
        searching?.cancel()
        guard !filter.isEmpty else {
            matches = []
            return
        }

        let root = root
        searching = Task {
            let files: [String] = if let allFiles { allFiles } else { await (try? ReviewGit.files(in: root)) ?? [] }
            guard !Task.isCancelled else { return }

            allFiles = files
            matches = Array(files.filter { $0.localizedCaseInsensitiveContains(filter) }.prefix(300))
        }
    }

    private static func list(_ folder: String, in root: String) async -> [FileEntry] {
        let directory = folder.isEmpty ? root : root + "/" + folder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }

        let paths = names.filter { $0 != ".git" }.map { folder.isEmpty ? $0 : folder + "/" + $0 }
        let ignored = await ReviewGit.ignored(paths, in: root)
        let entries = paths.map { path in
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &isFolder)
            return FileEntry(path: path, name: (path as NSString).lastPathComponent, isFolder: isFolder.boolValue, isIgnored: ignored.contains(path))
        }
        return entries.sorted { left, right in
            if left.isFolder != right.isFolder { return left.isFolder }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}
