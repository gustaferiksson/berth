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

    @Test func replayNeedsMoreMatchingEntriesThanTheBaseline() {
        let older = RemoteEntry(id: "u0", kind: .prompt, text: "continue", date: sent.addingTimeInterval(1000))
        let reply = RemoteEntry(id: "a0", kind: .reply, text: "continue")
        let suffix = RemoteEntry(id: "u1", kind: .prompt, text: "please continue")
        let replay = [older, reply, suffix]
        let baseline = PendingPrompts.recordedCount(text: "continue", attachmentCount: 0, entries: replay)
        let pending = [PendingPrompt(text: "continue", sentAt: sent, baseline: baseline)]
        let recorded = RemoteEntry(id: "u2", kind: .prompt, text: "continue", date: sent.addingTimeInterval(-1000))

        #expect(baseline == 1)
        #expect(PendingPrompts.reconcile(pending, entries: replay, queued: [], now: sent) == pending)
        #expect(PendingPrompts.reconcile(pending, entries: replay + [recorded], queued: [], now: sent).isEmpty)
    }

    @Test func matchesTrimmedTextAndBothKindsOfAttachmentToken() {
        let upload = "@/Cache/RemoteUploads/12345678-abcd-1234-ABCD-123456789abc/file.txt"
        let recorded = RemoteEntry(id: "u0", kind: .prompt, text: "\(upload) read this [Image #2]  \n")
        let pending = [PendingPrompt(text: "  read this\n", sentAt: sent, attachmentCount: 2, baseline: 0)]
        let differentCount = [PendingPrompt(text: "read this", sentAt: sent, attachmentCount: 1, baseline: 0)]

        #expect(PendingPrompts.reconcile(pending, entries: [recorded], queued: [], now: sent).isEmpty)
        #expect(PendingPrompts.reconcile(differentCount, entries: [recorded], queued: [], now: sent) == differentCount)
        #expect(PendingPrompts.unqueued(pending, queued: [recorded.text]).isEmpty)
        #expect(PendingPrompts.unqueued(differentCount, queued: ["read this"]).isEmpty)
    }

    @Test func matchesAnImagePromptWhoseRecordedTextLacksTheToken() {
        let pending = [PendingPrompt(text: "[Image #1] this diff  still\nhas corners", sentAt: sent)]
        let recorded = RemoteEntry(id: "u0", kind: .prompt, text: "this diff still has corners", date: sent, images: [Data([1])])
        let unrelated = RemoteEntry(id: "u1", kind: .prompt, text: "other", date: sent.addingTimeInterval(5))

        #expect(PendingPrompts.reconcile(pending, entries: [recorded], queued: [], now: sent).isEmpty)
        #expect(PendingPrompts.reconcile(pending, entries: [unrelated], queued: [], now: sent).isEmpty)
    }

    @Test func keepsFailedPromptsPastGraceAndIgnoresMatchingEntries() {
        let pending = [PendingPrompt(text: "continue", sentAt: sent, baseline: 0, isFailed: true)]
        let recorded = RemoteEntry(id: "u0", kind: .prompt, text: "continue")
        let now = sent.addingTimeInterval(PendingPrompts.grace + 1)

        #expect(PendingPrompts.reconcile(pending, entries: [recorded], queued: [], now: now) == pending)
        #expect(PendingPrompts.reconcile(pending, entries: [], queued: [recorded.text], now: now) == pending)
        #expect(PendingPrompts.unqueued(pending, queued: [recorded.text]) == pending)
    }
}
