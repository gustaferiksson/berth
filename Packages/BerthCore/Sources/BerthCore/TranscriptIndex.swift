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

    public var searchSources: [TranscriptSearchIndex.Source] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        return entries.flatMap { path, entry -> [TranscriptSearchIndex.Source] in
            guard let summary = entry.summary else { return [] }
            let url = URL(filePath: path)
            let subagents = (try? FileManager.default.contentsOfDirectory(at: url.deletingPathExtension().appending(path: "subagents"), includingPropertiesForKeys: Array(keys))) ?? []
            return [TranscriptSearchIndex.Source(sessionID: summary.id, url: url, modified: entry.modified, size: entry.size)]
                + subagents.compactMap { file in
                    guard file.pathExtension == "jsonl", let values = try? file.resourceValues(forKeys: keys), let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
                    return TranscriptSearchIndex.Source(sessionID: summary.id, url: file, modified: modified, size: size)
                }
        }
    }
}
