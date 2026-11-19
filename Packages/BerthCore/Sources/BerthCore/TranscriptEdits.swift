import Foundation

public struct TranscriptEdits: Sendable {
    static let tools = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let toolNames = tools.map { Array(#""name":"\#($0)""#.utf8) }
    static let toolUse = Array(#""type":"tool_use""#.utf8)
    static let sidechain = Array(#""isSidechain":true"#.utf8)
    static let chunkBytes = 4 << 20

    public private(set) var end = 0
    public private(set) var repositories: [String: String] = [:]
    private var directories: [String: (identity: String, folder: String)?] = [:]

    public init() {}

    public mutating func read(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return }

        defer { try? handle.close() }
        if Int(size) < end { self = Self() }
        guard (try? handle.seek(toOffset: UInt64(end))) != nil else { return }

        var buffer = Data()
        while let chunk = try? handle.read(upToCount: Self.chunkBytes), !chunk.isEmpty {
            buffer.append(chunk)
            let consumed = apply(buffer)
            end += consumed
            buffer = Data(buffer.dropFirst(consumed))
        }
    }

    mutating func apply(_ data: Data) -> Int {
        var paths: [String] = []
        let consumed = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }

            var start = 0
            while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
                let line = UnsafeRawBufferPointer(rebasing: buffer[start..<base.distance(to: newline)])
                start = base.distance(to: newline) + 1
                let find = { (pattern: [UInt8]) in memmem(line.baseAddress, line.count, pattern, pattern.count) }
                guard find(Self.toolUse) != nil, Self.toolNames.contains(where: { find($0) != nil }), find(Self.sidechain) == nil,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
                else { continue }

                for item in content where item["type"] as? String == "tool_use" && Self.tools.contains(item["name"] as? String ?? "") {
                    guard let input = item["input"] as? [String: Any], let path = input["file_path"] as? String ?? input["notebook_path"] as? String else { continue }

                    paths.append(path)
                }
            }
            return start
        }
        for path in paths where path.hasPrefix("/") {
            let directory = (path as NSString).deletingLastPathComponent
            let found = directories[directory] ?? RepositoryRoot.worktree(containing: directory)
            directories[directory] = .some(found)
            guard let found else { continue }

            repositories[found.identity] = repositories[found.identity] ?? found.folder
        }
        return consumed
    }
}
