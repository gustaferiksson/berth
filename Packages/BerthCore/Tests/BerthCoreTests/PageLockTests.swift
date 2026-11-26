@testable import BerthCore
import Foundation
import Testing

struct PageLockTests {
    private static let samePageURLs = [
        ("https://example.com/docs?sort=old", "https://example.com/docs?sort=new"),
        ("https://example.com/docs#intro", "https://example.com/docs#details"),
        ("https://example.com/docs", "https://example.com/docs/"),
        ("https://example.com", "https://example.com/"),
        ("HTTPS://EXAMPLE.COM/docs", "https://example.com/docs"),
        ("file:///tmp/docs.html#intro", "file:///tmp/docs.html"),
    ]

    private static let differentPageURLs = [
        ("https://example.com/docs", "https://example.com/status"),
        ("https://example.com/docs", "https://example.net/docs"),
        ("https://example.com:8443/docs", "https://example.com:9443/docs"),
        ("https://example.com/docs", "http://example.com/docs"),
        ("https://example.com/docs", "https://example.com/Docs"),
        ("https://example.com/docs%2Fstatus", "https://example.com/docs/status"),
        ("file:///tmp/docs.html", "file:///tmp/status.html"),
    ]

    @Test(arguments: samePageURLs) func samePage(first: String, second: String) throws {
        let firstURL = try #require(URL(string: first))
        let secondURL = try #require(URL(string: second))
        #expect(PageLock.isSamePage(firstURL, secondURL))
    }

    @Test(arguments: differentPageURLs) func differentPages(first: String, second: String) throws {
        let firstURL = try #require(URL(string: first))
        let secondURL = try #require(URL(string: second))
        #expect(!PageLock.isSamePage(firstURL, secondURL))
    }
}
