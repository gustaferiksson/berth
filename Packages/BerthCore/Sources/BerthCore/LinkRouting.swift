import Foundation

public enum LinkDestination {
    case berth, system

    public static func resolve(_ url: URL, opensGitHubInBerth: Bool, opensConversationLinksInBerth: Bool) -> Self {
        guard WebAddress.allows(url) else { return .system }

        let host = url.host(percentEncoded: false)?.lowercased()
        let isGitHub = host == "github.com" || host == "www.github.com"
        return opensGitHubInBerth && isGitHub || opensConversationLinksInBerth ? .berth : .system
    }
}
