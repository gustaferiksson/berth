import Foundation

public enum PageLock {
    public static func isSamePage(_ first: URL, _ second: URL) -> Bool {
        guard first.scheme?.lowercased() == second.scheme?.lowercased(),
              first.host(percentEncoded: false)?.lowercased() == second.host(percentEncoded: false)?.lowercased(),
              first.port == second.port
        else { return false }

        let firstPath = first.path(percentEncoded: true)
        let secondPath = second.path(percentEncoded: true)
        return (firstPath.hasSuffix("/") ? firstPath.dropLast() : firstPath[...])
            == (secondPath.hasSuffix("/") ? secondPath.dropLast() : secondPath[...])
    }
}
