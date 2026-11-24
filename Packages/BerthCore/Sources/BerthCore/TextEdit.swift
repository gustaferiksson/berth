import Foundation

public struct TextEdit: Equatable {
    public let range: NSRange
    public let replacement: String

    public init(from old: String, to new: String) {
        let old = old as NSString
        let new = new as NSString
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        range = NSRange(location: prefix, length: old.length - prefix - suffix)
        replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
    }

    public func mapped(_ location: Int) -> Int {
        if location <= range.location { return location }
        if location >= NSMaxRange(range) { return location - range.length + (replacement as NSString).length }
        return range.location
    }
}
