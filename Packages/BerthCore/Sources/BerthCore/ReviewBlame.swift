import Foundation

public struct ReviewBlame: Equatable, Sendable {
    public let hash: String
    public let author: String
    public let authorTime: Date
    public let summary: String

    public var isUncommitted: Bool { hash.utf8.allSatisfy { $0 == 0x30 } }

    public static func parse(_ output: String) -> [Int: Self] {
        var commits: [String: Self] = [:]
        var entries: [Int: Self] = [:]
        var header: (hash: String, line: Int)?
        var author: String?
        var time: Int64?
        var summary: String?

        for bytes in output.utf8.split(separator: 0x0A) {
            if bytes.first == 0x09 {
                if let header {
                    if let author, let time, let summary {
                        commits[header.hash] = Self(hash: header.hash, author: author, authorTime: Date(timeIntervalSince1970: TimeInterval(time)), summary: summary)
                    }
                    entries[header.line] = commits[header.hash]
                }
                header = nil
                author = nil
                time = nil
                summary = nil
                continue
            }
            let line = String(decoding: bytes, as: UTF8.self)
            if header == nil {
                let fields = line.split(separator: " ")
                guard (3...4).contains(fields.count), [40, 64].contains(fields[0].utf8.count), fields[0].allSatisfy(\.isHexDigit),
                      Int(fields[1]) != nil, let number = Int(fields[2]), number > 0
                else { continue }

                header = (String(fields[0]), number)
            } else if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                time = Int64(line.dropFirst("author-time ".count))
            } else if line.hasPrefix("summary ") {
                summary = String(line.dropFirst("summary ".count))
            }
        }
        return entries
    }
}
