public enum ReplayQueries {
    private static let escape: UInt8 = 0x1B
    private static let bell: UInt8 = 0x07
    private static let oscQueryIDs: Set<Int> = [4, 5, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 52]
    private static let windowReports: Set<Int> = [11, 13, 14, 15, 16, 18, 19, 20, 21]

    /// Scrollback with the terminal queries removed. A terminal answers every query it parses, and on a replay the answers reach a shell that never asked.
    public static func removed(from bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == escape, index + 1 < bytes.count else {
                output.append(bytes[index])
                index += 1
                continue
            }

            let end = sequenceEnd(in: bytes, from: index)
            if !isQuery(bytes[index..<end]) { output += bytes[index..<end] }
            index = end
        }
        return output
    }

    private static func sequenceEnd(in bytes: [UInt8], from start: Int) -> Int {
        let kind = bytes[start + 1]
        if kind == UInt8(ascii: "[") {
            let final = bytes[(start + 2)...].firstIndex { (0x40...0x7E).contains($0) }
            return final.map { $0 + 1 } ?? bytes.count
        }
        guard kind == UInt8(ascii: "]") || kind == UInt8(ascii: "P") else { return start + 2 }

        var index = start + 2
        while index < bytes.count {
            if bytes[index] == bell, kind == UInt8(ascii: "]") { return index + 1 }
            if bytes[index] == escape, index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\") { return index + 2 }

            index += 1
        }
        return bytes.count
    }

    private static func isQuery(_ sequence: ArraySlice<UInt8>) -> Bool {
        let body = Array(sequence.dropFirst(2))
        switch sequence[sequence.startIndex + 1] {
        case UInt8(ascii: "["):
            return isCSIQuery(body)

        case UInt8(ascii: "]"):
            let text = String(decoding: body.prefix { $0 != bell && $0 != escape }, as: UTF8.self)
            let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            return parts.last == "?" && parts.first.flatMap { Int($0) }.map(oscQueryIDs.contains) == true

        case UInt8(ascii: "P"):
            return body.starts(with: Array("$q".utf8)) || body.starts(with: Array("+q".utf8))

        default:
            return false
        }
    }

    private static func isCSIQuery(_ body: [UInt8]) -> Bool {
        guard let final = body.last else { return false }

        let parameters = body.dropLast().filter { (0x30...0x3F).contains($0) }
        let intermediates = body.dropLast().filter { (0x20...0x2F).contains($0) }
        let text = String(decoding: parameters, as: UTF8.self)
        let numbers = text.drop { !$0.isNumber }.split(separator: ";").compactMap { Int($0) }
        switch (Character(UnicodeScalar(final)), Character(UnicodeScalar(intermediates.first ?? 0x20))) {
        case ("n", " "): return true
        case ("c", " "): return true
        case ("q", " "): return text.hasPrefix(">")
        case ("u", " "): return text == "?"
        case ("p", "$"): return true
        case ("S", " "): return text.hasPrefix("?")
        case ("x", " "): return text.isEmpty || numbers.count == 1
        case ("t", " "): return numbers.count == 1 && windowReports.contains(numbers[0])
        default: return false
        }
    }
}
