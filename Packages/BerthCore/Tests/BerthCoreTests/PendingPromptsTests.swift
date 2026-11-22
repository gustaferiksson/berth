@testable import BerthCore
import Foundation
import Testing

struct PendingPromptsTests {
    private let sent = Date(timeIntervalSince1970: 1000)

    @Test func showsASentPromptBeforeTheTranscriptHasIt() {
        let pending = [PendingPrompt(text: "run the tests", sentAt: sent)]
        let kept = PendingPrompts.reconcile(pending, entries: [], queued: [], now: sent.addingTimeInterval(1))

        #expect(PendingPrompts.shown(kept, queued: []) == ["run the tests"])
    }

    @Test func showsEachPromptOnceWhileClaudeCodeQueuesIt() {
        let pending = [PendingPrompt(text: "second", sentAt: sent)]
        let kept = PendingPrompts.reconcile(pending, entries: [], queued: ["first", "second"], now: sent.addingTimeInterval(1))

        #expect(PendingPrompts.shown(kept, queued: ["first", "second"]) == ["first", "second"])
    }

    @Test func handsOverToTheRealPromptRecord() {
        let pending = [PendingPrompt(text: "second", sentAt: sent)]
        let recorded = RemoteEntry(id: "u1", kind: .prompt, text: "second", date: sent.addingTimeInterval(2))

        #expect(PendingPrompts.reconcile(pending, entries: [recorded], queued: [], now: sent.addingTimeInterval(3)).isEmpty)
    }

    @Test func ignoresAnOlderPromptWithTheSameText() {
        let pending = [PendingPrompt(text: "continue", sentAt: sent)]
        let older = RemoteEntry(id: "u0", kind: .prompt, text: "continue", date: sent.addingTimeInterval(-60))
        let kept = PendingPrompts.reconcile(pending, entries: [older], queued: [], now: sent.addingTimeInterval(1))

        #expect(kept.count == 1)
    }

    @Test func dropsAQueuedPromptThatWasRemovedWithoutRunning() {
        let pending = [PendingPrompt(text: "second", sentAt: sent)]
        let queued = PendingPrompts.reconcile(pending, entries: [], queued: ["second"], now: sent.addingTimeInterval(1))

        #expect(PendingPrompts.reconcile(queued, entries: [], queued: [], now: sent.addingTimeInterval(2)).isEmpty)
    }

    @Test func dropsAPromptTheTranscriptNeverShows() {
        let pending = [PendingPrompt(text: "/model", sentAt: sent)]

        #expect(PendingPrompts.reconcile(pending, entries: [], queued: [], now: sent.addingTimeInterval(11)).isEmpty)
    }
}
