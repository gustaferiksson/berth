@testable import BerthCore
import Foundation
import Testing

struct TineCompletionTests {
    private func reply(_ items: String, pending: Bool = false) -> Data {
        Data(#"{"version":1,"pending":\#(pending),"items":[\#(items)]}"#.utf8)
    }

    private func completion(_ reply: TineReply) -> TineCompletion {
        guard case let .completion(completion) = reply else { Issue.record("expected a completion"); return TineCompletion(isPending: false, items: []) }

        return completion
    }

    @Test func requestDropsTheBangAndShiftsTheCaret() throws {
        let request = try #require(TineRequest(draft: "!git ch", caret: 7, cwd: "/tmp"))

        #expect(request.wire == "complete\u{1f}6\u{1f}/tmp\u{1f}\u{1f}git ch")
    }

    @Test func requestRefusesDraftsWithoutABangOrCaretBeforeIt() {
        #expect(TineRequest(draft: "git ch", caret: 6, cwd: "/") == nil)
        #expect(TineRequest(draft: "!git", caret: 0, cwd: "/") == nil)
    }

    @Test func requestSendsOnlyTheCaretLine() throws {
        let draft = "!echo one\nls -l\nwc"
        let request = try #require(TineRequest(draft: draft, caret: 15, cwd: "/"))

        #expect(request.wire == "complete\u{1f}5\u{1f}/\u{1f}\u{1f}ls -l")
        let item = #"{"name":"-la","kind":"option","edit":{"start":3,"end":5,"text":"-la ","cursor":4}}"#
        let parsed = try completion(request.parse(reply(item))).items[0]
        #expect(parsed.replacement == NSRange(location: 13, length: 2))
        #expect(parsed.caret == 14)
        #expect(((draft as NSString).replacingCharacters(in: parsed.replacement, with: parsed.text)) == "!echo one\nls -la \nwc")
    }

    @Test func offsetsStayInUTF16WithEmojiAndAccents() throws {
        let draft = "!echo 😀å cat"
        let caret = (draft as NSString).length
        let request = try #require(TineRequest(draft: draft, caret: caret, cwd: "/"))

        #expect(request.wire.hasSuffix("\u{1f}echo 😀å cat"))
        #expect(request.wire.contains("complete\u{1f}\(caret - 1)\u{1f}"))
        let item = #"{"name":"cátalog","kind":"file","matches":[0,1],"edit":{"start":9,"end":12,"text":"cátalog ","cursor":17}}"#
        let parsed = try completion(request.parse(reply(item))).items[0]
        #expect(parsed.replacement == NSRange(location: 10, length: 3))
        #expect((draft as NSString).substring(with: parsed.replacement) == "cat")
        #expect(parsed.caret == 18)
        #expect(parsed.matches == [0, 1])
    }

    @Test func parsesPendingAndFields() throws {
        let request = try #require(TineRequest(draft: "!git ch", caret: 7, cwd: "/"))
        let item = #"{"name":"rm -rf","description":"Delete","kind":"mystery","dangerous":true,"matches":[],"edit":{"start":0,"end":2,"text":"rm ","cursor":3}}"#
        let parsed = try completion(request.parse(reply(item, pending: true)))

        #expect(parsed.isPending)
        #expect(parsed.items[0].kind == .generic)
        #expect(parsed.items[0].isDangerous)
        #expect(parsed.items[0].description == "Delete")
        #expect(parsed.items[0].replacement == NSRange(location: 1, length: 2))
    }

    @Test func parsesARealTineReply() throws {
        let request = try #require(TineRequest(draft: "!git ch", caret: 7, cwd: "/tmp"))
        let items = try completion(request.parse(Data(#"{"version":1,"pending":false,"items":[{"name":"checkout","dangerous":false,"matches":[0,1],"description":"Switch branches or restore working tree files","kind":"subcommand","edit":{"text":"checkout","cursor":12,"end":6,"start":4}},{"name":"cherry-pick","dangerous":false,"matches":[0,1],"description":"Apply the changes introduced by some existing commits","kind":"subcommand","edit":{"text":"cherry-pick ","cursor":16,"end":6,"start":4}},{"name":"fetch","matches":[3,4],"kind":"subcommand","edit":{"text":"fetch","cursor":9,"end":6,"start":4}},{"name":"--exec-path","dangerous":false,"matches":[5,10],"description":"Get or set GIT_EXEC_PATH for core Git programs","kind":"option","edit":{"text":"--exec-path","cursor":15,"end":6,"start":4}}]}"#.utf8))).items

        #expect(items.map(\.name) == ["checkout", "cherry-pick", "fetch", "--exec-path"])
        #expect(items[2].matches == [3, 4])
        #expect(items[3].matches == [5, 10])
        #expect(items[3].description == "Get or set GIT_EXEC_PATH for core Git programs")
        #expect(items[1].replacement == NSRange(location: 5, length: 2))
        #expect(items[1].caret == 17)
        #expect(("!git ch" as NSString).replacingCharacters(in: items[1].replacement, with: items[1].text) == "!git cherry-pick ")
    }

    @Test func emptyReplyHasNoItems() throws {
        let request = try #require(TineRequest(draft: "!zz", caret: 3, cwd: "/"))

        #expect(try request.parse(reply("")) == .completion(TineCompletion(isPending: false, items: [])))
    }

    @Test func oldTineReplyIsUnsupported() throws {
        let request = try #require(TineRequest(draft: "!git", caret: 4, cwd: "/"))

        #expect(try request.parse(Data("unknown command".utf8)) == .unsupported)
    }

    @Test func clientRoundTripsThroughASocket() async throws {
        let path = "/tmp/tine-test-\(UUID().uuidString.prefix(8)).sock"
        let server = TineStubServer(path: path) { _ in
            #"{"version":1,"pending":false,"items":[{"name":"checkout","kind":"subcommand","matches":[0,1],"edit":{"start":4,"end":6,"text":"checkout ","cursor":13}}]}"#
        }
        try server.start()
        defer { server.stop() }
        let request = try #require(TineRequest(draft: "!git ch", caret: 7, cwd: "/tmp"))

        let result = try await completion(TineClient(socketPath: path, launch: {}).complete(request))

        #expect(result.items.map(\.name) == ["checkout"])
        #expect(result.items[0].caret == 14)
    }

    @Test func clientReportsAMissingSocketAfterLaunching() async throws {
        let request = try #require(TineRequest(draft: "!git", caret: 4, cwd: "/"))
        let launches = LaunchCount()
        let client = TineClient(socketPath: "/tmp/tine-missing-\(UUID().uuidString.prefix(8)).sock") { launches.increment() }

        await #expect(throws: TineError.unavailable) { try await client.complete(request) }
        #expect(launches.value == 1)
    }
}

private final class LaunchCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
