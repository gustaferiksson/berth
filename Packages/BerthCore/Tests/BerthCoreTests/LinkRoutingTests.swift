@testable import BerthCore
import Foundation
import Testing

struct LinkRoutingTests {
    @Test func routesGitHubLinks() throws {
        for text in ["https://github.com/acme/repo/pull/1", "http://www.GITHUB.com/acme/repo/issues/1"] {
            let url = try #require(URL(string: text))
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: false, opensConversationLinksInBerth: false) == .system)
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: true, opensConversationLinksInBerth: false) == .berth)
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: false, opensConversationLinksInBerth: true) == .berth)
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: true, opensConversationLinksInBerth: true) == .berth)
        }
    }

    @Test func routesOtherWebLinksByTheConversationSetting() throws {
        for text in ["https://example.com", "https://github.com.example.com", "https://gist.github.com"] {
            let url = try #require(URL(string: text))
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: false, opensConversationLinksInBerth: false) == .system)
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: true, opensConversationLinksInBerth: false) == .system)
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: false, opensConversationLinksInBerth: true) == .berth)
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: true, opensConversationLinksInBerth: true) == .berth)
        }
    }

    @Test func rejectsURLsTheBrowserDisallows() throws {
        for text in ["ftp://github.com", "mailto:user@github.com", "https://user@github.com", "https:/github.com", "github.com"] {
            let url = try #require(URL(string: text))
            #expect(LinkDestination.resolve(url, opensGitHubInBerth: true, opensConversationLinksInBerth: true) == .system)
        }
    }
}
