import Foundation

public enum LoopbackURL {
    public static let hosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.user == nil, let host = url.host(percentEncoded: false)?.lowercased() else { return false }

        return hosts.contains(host)
    }

    public static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "http://" + trimmed), allows(url) else { return nil }

        return url
    }
}
