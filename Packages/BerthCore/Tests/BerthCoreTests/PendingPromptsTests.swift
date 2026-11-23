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

    @Test(arguments: [nil, 0] as [Int?]) func matchesQueueTextWithDifferentWhitespaceTagsAndImageTokens(baseline: Int?) {
        let pending = [PendingPrompt(text: "check  this [Image #1]", sentAt: sent, baseline: baseline, promptBaseline: baseline)]
        let queued = ["check\n <context>this</context> [Image #2] [Image #3]"]
        let recorded = RemoteEntry(id: "u1", kind: .prompt, text: "something else", date: sent)
        let kept = PendingPrompts.reconcile(pending, entries: [recorded], queued: queued, now: sent.addingTimeInterval(11))

        #expect(kept.first?.wasQueued == true)
        #expect(PendingPrompts.shown(kept, queued: queued) == queued)
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

    @Test func matchesPromptAfterAngleBracketTextWasStripped() {
        let earlier = PendingPrompt(text: "finish the sketch", sentAt: sent.addingTimeInterval(-1))
        let prompt = PendingPrompt(text: "use Array<String> here", sentAt: sent)
        let recorded = RemoteEntry(id: "u1", kind: .prompt, text: "use Array  here", date: sent)

        #expect(PendingPrompts.reconcile([earlier, prompt], entries: [recorded], queued: [], now: sent).map(\.text) == [earlier.text])
    }

    @Test func matchesPromptWithContextAddedOnBothSides() {
        let earlier = PendingPrompt(text: "finish the sketch", sentAt: sent.addingTimeInterval(-1))
        let prompt = PendingPrompt(text: "draw the floor plan", sentAt: sent)
        let recorded = RemoteEntry(id: "u1", kind: .prompt, text: "An editor is open.\ndraw the floor plan\nA hook has completed.", date: sent)

        #expect(PendingPrompts.reconcile([earlier, prompt], entries: [recorded], queued: [], now: sent).map(\.text) == [earlier.text])
    }

    @Test func fallsBackToHumanEntriesInSendOrderAcrossRefreshes() {
        let first = PendingPrompt(text: "draw a circle", sentAt: sent)
        let second = PendingPrompt(text: "draw a square", sentAt: sent.addingTimeInterval(1))
        let older = RemoteEntry(id: "u0", kind: .prompt, text: "old message", date: sent.addingTimeInterval(-2))
        let bash = RemoteEntry(id: "shell", kind: .prompt, text: "pwd", name: "bash", date: sent)
        let recordedFirst = RemoteEntry(id: "u1", kind: .prompt, text: "make a round shape", date: sent)
        let recordedSecond = RemoteEntry(id: "u2", kind: .prompt, text: "make a four-sided shape", date: sent.addingTimeInterval(1))
        let history = [older, bash, recordedFirst]
        let now = sent.addingTimeInterval(1)
        let kept = PendingPrompts.reconcile([second, first], entries: history, queued: [], now: now)

        #expect(kept.map(\.text) == [second.text])
        #expect(PendingPrompts.reconcile(kept, entries: history, queued: [], now: now) == kept)
        #expect(PendingPrompts.reconcile(kept, entries: history + [recordedSecond], queued: [], now: now).isEmpty)
        #expect(PendingPrompts.reconcile([second, first], entries: history + [recordedSecond], queued: [], now: now).isEmpty)
    }

    @Test func fallbackIgnoresRecordsBeforeTheSendWindow() {
        let pending = [PendingPrompt(text: "draw a circle", sentAt: sent)]
        let older = RemoteEntry(id: "u0", kind: .prompt, text: "make a round shape", date: sent.addingTimeInterval(-2))
        let onBoundary = RemoteEntry(id: "u1", kind: .prompt, text: "make a round shape", date: sent.addingTimeInterval(-1))

        #expect(PendingPrompts.reconcile(pending, entries: [older], queued: [], now: sent) == pending)
        #expect(PendingPrompts.reconcile(pending, entries: [older, onBoundary], queued: [], now: sent).isEmpty)
    }

    @Test func fallbackCountsOnlyHumanEntriesAgainstTheRemoteBaseline() {
        let older = RemoteEntry(id: "u0", kind: .prompt, text: "old message", date: sent.addingTimeInterval(1000))
        let bash = RemoteEntry(id: "shell", kind: .prompt, text: "pwd", name: "bash", date: sent)
        let reply = RemoteEntry(id: "a0", kind: .reply, text: "reply")
        let recorded = RemoteEntry(id: "u1", kind: .prompt, text: "make a round shape", date: sent.addingTimeInterval(-1000))
        let pending = [PendingPrompt(text: "draw a circle", sentAt: sent, baseline: 0, promptBaseline: 1)]
        let history = [older, reply, bash]

        #expect(PendingPrompts.reconcile(pending, entries: history, queued: [], now: sent) == pending)
        #expect(PendingPrompts.reconcile(pending, entries: history + [recorded], queued: [], now: sent).isEmpty)
    }

    @Test func exactRemoteMatchClaimsOnlyOneNewEntry() {
        let older = RemoteEntry(id: "u0", kind: .prompt, text: "continue")
        let recorded = RemoteEntry(id: "u1", kind: .prompt, text: "continue")
        let first = PendingPrompt(text: "continue", sentAt: sent, baseline: 1, promptBaseline: 1)
        let second = PendingPrompt(text: "continue", sentAt: sent.addingTimeInterval(1), baseline: 1, promptBaseline: 1)
        let now = sent.addingTimeInterval(1)
        let kept = PendingPrompts.reconcile([first, second], entries: [older, recorded], queued: [], now: now)

        #expect(kept.map(\.sentAt) == [second.sentAt])
        #expect(PendingPrompts.reconcile(kept, entries: [older, recorded], queued: [], now: now) == kept)
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
