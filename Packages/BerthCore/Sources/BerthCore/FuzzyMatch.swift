import Foundation

public enum FuzzyMatch {
    public static func score(_ query: String, name: String, path: String) -> Int? {
        let query = query.lowercased()
        guard !query.isEmpty else { return 0 }
        let name = name.lowercased()
        let path = path.lowercased()
        if query.hasPrefix("/") { return path.hasPrefix(query) ? 500 : nil }
        if name.hasPrefix(query) { return 400 }
        if name.contains(query) { return 300 }
        if isSubsequence(query, of: name) { return 200 }
        if path.contains(query) { return 100 }
        return isSubsequence(query, of: path) ? 50 : nil
    }

    static func isSubsequence(_ query: String, of text: String) -> Bool {
        var remaining = query[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
