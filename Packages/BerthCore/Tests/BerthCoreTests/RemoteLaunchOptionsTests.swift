import BerthCore
import Foundation
import Testing

struct RemoteLaunchOptionsTests {
    @Test func sessionStartRoundTrips() throws {
        let start = RemoteSessionStart(folder: "/projects/acme", prompt: "Fix the build", agent: "codex", checkout: .worktree)
        let message = RemoteClientMessage.startSession(start)
        let decoded = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(message))

        guard case let .startSession(decodedStart) = decoded else {
            Issue.record("wrong case")
            return
        }

        #expect(decodedStart == start)
    }

    @Test func sessionStartWithoutOptionsDecodes() throws {
        let json = Data(#"{"folder":"/projects/acme","prompt":""}"#.utf8)
        let start = try JSONDecoder().decode(RemoteSessionStart.self, from: json)

        #expect(start.agent == nil)
        #expect(start.checkout == nil)
    }

    @Test func launchOptionsRoundTrip() throws {
        let options = RemoteLaunchOptions(agents: [RemoteLaunchAgent(id: "claude", name: "Claude", asset: "HarnessClaude", worktreeFolders: ["/projects/acme"])], defaultAgent: "claude", startsInWorktree: true)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(RemoteServerMessage.launchOptions(options)))

        guard case let .launchOptions(decodedOptions) = decoded else {
            Issue.record("wrong case")
            return
        }

        #expect(decodedOptions == options)
    }

    @Test func inboxAndItemStartRoundTrip() throws {
        let item = RemoteInboxItem(kind: .pullRequest, repository: "acme/widgets", number: 12, title: "Fix the build", group: "Review Requested", isOpenable: false, updatedAt: Date(timeIntervalSinceReferenceDate: 0), author: "mara", branch: "fix/build", isDraft: false, checks: "passed")
        let inbox = RemoteInbox(pullRequests: [item], issues: nil)
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(RemoteServerMessage.inbox(inbox)))
        let start = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(RemoteClientMessage.startItem(kind: .issue, repository: "acme/widgets", number: 7)))

        guard case let .inbox(decodedInbox) = decoded, case let .startItem(kind, repository, number) = start else {
            Issue.record("wrong case")
            return
        }

        #expect(decodedInbox == inbox)
        #expect(item.id == "pullRequest/acme/widgets#12")
        #expect(kind == .issue && repository == "acme/widgets" && number == 7)
    }

    @Test func legacyNewSessionStillDecodes() throws {
        let decoded = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(RemoteClientMessage.newSession(folder: "/projects/acme", prompt: "Hi")))

        guard case let .newSession(folder, prompt) = decoded else {
            Issue.record("wrong case")
            return
        }

        #expect(folder == "/projects/acme" && prompt == "Hi")
    }
}
