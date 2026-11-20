import Foundation

public enum TaskOutput {
    public static func tail(_ url: URL, maxBytes: Int = 16 << 10, maxLines: Int = 50) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return nil }

        defer { try? handle.close() }
        let offset = max(0, Int(size) - maxBytes)
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.readToEnd() else { return nil }

        let text = String(decoding: data, as: UTF8.self).replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "").trimmingCharacters(in: .newlines)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(offset > 0 ? 1 : 0)
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}
