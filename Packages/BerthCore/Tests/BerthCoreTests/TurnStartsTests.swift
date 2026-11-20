@testable import BerthCore
import Foundation
import Testing

struct TurnStartsTests {
    private func live(_ status: String) -> [String: LiveSession] {
        ["s": try! JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":1,"sessionId":"s","cwd":"/","status":"\#(status)"}"#.utf8))]
    }

    private func session(prompt: TimeInterval, typed: TimeInterval?) -> [String: SessionSummary] {
        ["s": SessionSummary(id: "s", cwd: "/", title: "s", lastActivity: Date(timeIntervalSince1970: 1000), lastPrompt: Date(timeIntervalSince1970: prompt), lastTypedPrompt: typed.map { Date(timeIntervalSince1970: $0) })]
    }

    @Test func queuedPromptMidTurnDoesNotResetTheStart() {
        var starts = TurnStarts()
        starts.update(live: live("busy"), sessions: session(prompt: 100, typed: 100))
        starts.update(live: live("busy"), sessions: session(prompt: 160, typed: 100))
        #expect(starts["s"] == Date(timeIntervalSince1970: 100))
    }

    @Test func newPromptAfterIdleStartsANewTurn() {
        var starts = TurnStarts()
        starts.update(live: live("busy"), sessions: session(prompt: 100, typed: 100))
        starts.update(live: live("idle"), sessions: session(prompt: 100, typed: 100))
        #expect(starts["s"] == nil)
        starts.update(live: live("busy"), sessions: session(prompt: 300, typed: 300))
        #expect(starts["s"] == Date(timeIntervalSince1970: 300))
    }

    @Test func typedPromptNewerThanTheRememberedStartReplacesIt() {
        var starts = TurnStarts()
        starts.update(live: live("busy"), sessions: session(prompt: 100, typed: 100))
        starts.update(live: live("busy"), sessions: session(prompt: 300, typed: 300))
        #expect(starts["s"] == Date(timeIntervalSince1970: 300))
    }

    @Test func tailWithoutPromptsKeepsTheRememberedStart() {
        var starts = TurnStarts()
        starts.update(live: live("busy"), sessions: session(prompt: 100, typed: 100))
        starts.update(live: live("waiting"), sessions: session(prompt: 100, typed: nil))
        starts.update(live: live("busy"), sessions: session(prompt: 100, typed: nil))
        #expect(starts["s"] == Date(timeIntervalSince1970: 100))
    }
}
