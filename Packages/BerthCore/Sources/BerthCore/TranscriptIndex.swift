import Foundation

public struct TranscriptIndex: Sendable {
    struct Entry: Sendable {
        let modified: Date
        let size: Int
        let summary: SessionSummary?
    }

    public let root: URL
    private var entries: [String: Entry] = [:]

    public init(root: URL) {
        self.root = root
    }

    public mutating func refresh() -> [SessionSummary] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let files = projects.flatMap { project in
            ((try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        let next = files.reduce(into: [String: Entry]()) { result, file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, let size = values.fileSize
            else { return }
            if let cached = entries[file.path], cached.modified == modified, cached.size == size {
                result[file.path] = cached
                return
            }
            result[file.path] = Entry(modified: modified, size: size, summary: Transcript.summary(of: file))
        }
        entries = next
        return next.values.compactMap(\.summary)
    }

    public func transcript(ofSession id: String) -> URL? {
        entries.first { $0.value.summary?.id == id }.map { URL(filePath: $0.key) }
    }
}
