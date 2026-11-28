import BerthCore
import Foundation
import Testing

struct PullRequestMemoryTests {
    private func link(_ number: Int, _ repository: String = "acme/billing") -> PullRequestLink {
        PullRequestLink(repository: repository, number: number)
    }

    @Test func keepsLinksTheTranscriptWindowNoLongerShows() {
        var memory = PullRequestMemory(storage: nil)
        _ = memory.merged([link(12), link(11), link(10)], of: "a")
        var restarted = PullRequestMemory(storage: memory.storage)

        #expect(restarted.merged([], of: "a") == [link(12), link(11), link(10)])
        #expect(restarted.merged([link(13), link(11)], of: "a") == [link(13), link(11), link(12), link(10)])
    }

    @Test func remembersAddedPullRequestsWithTheirCloneAndMatchesRepositoriesIgnoringCase() {
        var memory = PullRequestMemory(storage: nil)
        memory.add(link(7, "acme/api"), root: "/work/api", to: "a")
        _ = memory.merged([link(7, "Acme/API")], of: "a")

        #expect(memory.rooted(of: "a").map(\.root) == ["/work/api"])
        #expect(memory.merged([], of: "a").count == 1)
    }

    @Test func boundsEachSessionAndPrunesGoneSessions() {
        var memory = PullRequestMemory(storage: nil)
        _ = memory.merged((1...150).map { link($0) }, of: "a")
        _ = memory.merged([link(1)], of: "b")
        memory.prune(keeping: ["a"])

        #expect(memory.merged([], of: "a").count == PullRequestMemory.limit)
        #expect(memory.merged([], of: "b").isEmpty)
    }

    @Test func carriesLinksToTheSessionThatContinuedIt() {
        var memory = PullRequestMemory(storage: nil)
        _ = memory.merged([link(1)], of: "old")
        _ = memory.merged([link(2)], of: "new")
        memory.move("old", to: "new")

        #expect(memory.merged([], of: "new") == [link(2), link(1)])
        #expect(memory.merged([], of: "old").isEmpty)
    }

    @Test func ignoresUnreadableStorage() {
        var memory = PullRequestMemory(storage: "not json")

        #expect(memory.merged([], of: "a").isEmpty)
    }
}
