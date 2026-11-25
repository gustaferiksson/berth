import Foundation

public enum TaskOutput {
    public static func tail(_ url: URL, maxBytes: Int = 16 << 10, maxLines: Int = 50) -> String? {
        guard maxBytes > 0, maxLines > 0,
              (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }

        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        let offset = size - min(size, UInt64(maxBytes))
        let start = offset > 0 ? offset - 1 : offset
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start))
        else { return "" }

        let bytes = data.dropFirst(offset > 0 ? 1 : 0)
        let complete = offset > 0 && data.first != 0x0A ? bytes.drop(while: { $0 != 0x0A }).dropFirst() : bytes
        let visible = complete.isEmpty ? bytes.drop(while: { (0x80...0xBF).contains($0) }) : complete
        let text = TerminalText.plain(Array(visible)).trimmingCharacters(in: .newlines)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines).joined(separator: "\n")
    }
}
