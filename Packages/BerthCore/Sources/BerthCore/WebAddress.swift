import Foundation

public enum WebAddress {
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.user == nil else { return false }

        return url.host(percentEncoded: false)?.isEmpty == false
    }

    /// A typed address as a URL, or a search for it with `searchTemplate`, where `%s` stands for the query.
    public static func resolve(_ text: String, searchTemplate: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), allows(url) || ["about", "file"].contains(url.scheme?.lowercased()) { return url }

        let looksLikeHost = !trimmed.contains(" ") && (trimmed.contains(".") || trimmed.hasPrefix("localhost") || trimmed.contains(":"))
        let isLoopback = ["localhost", "127.0.0.1", "[::1]"].contains { trimmed.hasPrefix($0) }
        if looksLikeHost, let url = URL(string: (isLoopback ? "http://" : "https://") + trimmed), allows(url) { return url }

        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? trimmed
        return URL(string: searchTemplate.replacing("%s", with: query))
    }
}
