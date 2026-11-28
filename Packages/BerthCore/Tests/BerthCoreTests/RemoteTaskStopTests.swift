import BerthCore
import Foundation
import Testing

struct RemoteTaskStopTests {
    @Test func stopTaskMessageRoundTrips() throws {
        let request = RemoteClientMessage.stopTask(sessionID: "s", taskID: "bg-1")
        guard case let .stopTask(sessionID, taskID) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(request)) else { throw CancellationError() }

        #expect(sessionID == "s")
        #expect(taskID == "bg-1")
    }
}
