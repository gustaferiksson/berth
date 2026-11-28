import BerthCore
import Foundation
import Testing

struct RemoteSubagentTranscriptTests {
    @Test func transcriptMessagesRoundTrip() throws {
        let request = RemoteClientMessage.subagentTranscript(sessionID: "s", taskID: "a1")
        guard case let .subagentTranscript(sessionID, taskID) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(request)) else { throw CancellationError() }

        #expect(sessionID == "s")
        #expect(taskID == "a1")

        let entries = [
            RemoteEntry(id: "e1", kind: .prompt, text: "Audit the rows"),
            RemoteEntry(id: "e2", kind: .reply, text: "Done"),
        ]
        for sent in [entries, nil] {
            let reply = RemoteServerMessage.subagentTranscript(sessionID: "s", taskID: "a1", entries: sent)
            guard case let .subagentTranscript(replySessionID, replyTaskID, decoded) = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(reply)) else { throw CancellationError() }

            #expect(replySessionID == "s")
            #expect(replyTaskID == "a1")
            #expect(decoded == sent)
        }
    }

    @Test func oversizedTranscriptsKeepTheNewestEntries() {
        let chunk = String(repeating: "x", count: RemoteSubagentTranscriptFeature.byteBudget / 2 - 1)
        let entries = (0..<4).map { RemoteEntry(id: "e\($0)", kind: .reply, text: chunk) }

        #expect(RemoteSubagentTranscriptFeature.fitting(entries).map(\.id) == ["e2", "e3"])
        #expect(RemoteSubagentTranscriptFeature.fitting(Array(entries.prefix(2))).count == 2)
    }
}
