@testable import BerthCore
import Foundation
import Testing

struct TaskFormationTests {
    private let usage = IssueRef(repository: "acme/billing", number: 57)
    private let web = IssueRef(repository: "acme/web", number: 9)
    private let rounding = PullRequestLink(repository: "acme/billing", number: 212)

    private func session(_ id: String, age: Double = 0, repository: String = "acme/billing", extraRepositories: Set<String> = [], typed: [IssueRef] = [], closing: [IssueRef] = [], pullRequests: [PullRequestLink] = [], branches: [String] = []) -> TaskSession {
        TaskSession(id: id, lastPrompt: Date(timeIntervalSince1970: 1_800_000_000 - age), repository: repository, repositories: Set([repository]).union(extraRepositories), typedIssues: typed, closingIssues: closing, pullRequests: pullRequests, branches: branches)
    }

    private func form(_ sessions: [TaskSession], from state: TaskState = TaskState()) -> (state: TaskState, shown: [StoredTask], suggestions: [TaskSuggestion]) {
        var next = 0
        return TaskFormation.form(state, sessions: sessions) {
            next += 1
            return "task:\(next)"
        }
    }

    @Test func typedIssueURLsAreReadOldestFirstFromTypedPromptsOnly() {
        let records = Transcript.records(in: Data("""
        {"type":"user","cwd":"/x","timestamp":"2026-10-29T09:00:00.000Z","message":{"content":"see https://github.com/Acme/Billing/issues/57 and https://github.com/acme/web/issues/9."}}
        {"type":"user","timestamp":"2026-10-29T09:01:00.000Z","origin":{"kind":"task-notification"},"message":{"content":"https://github.com/acme/billing/issues/1"}}
        {"type":"user","timestamp":"2026-10-29T09:02:00.000Z","message":{"content":"also https://github.com/acme/billing/pull/3 and https://github.com/acme/billing/issues/57"}}
        """.utf8), dropFirst: false, dropLast: false)
        let summary = Transcript.summary(id: "a", folder: "-x", modified: .now, head: Array(records.prefix(1)), tail: Array(records.dropFirst()), earlierIssueRefs: [IssueRef(repository: "acme/infra", number: 4)])
        #expect(summary?.issueRefs == [IssueRef(repository: "acme/infra", number: 4), usage, web])
    }

    @Test func sessionsSharingATypedIssueFormATaskAcrossRepositories() {
        let result = form([session("a", typed: [usage]), session("b", age: 60, repository: "acme/web", typed: [usage]), session("c", age: 90)])
        #expect(result.shown.map(\.sessionIDs) == [["a", "b"]])
        #expect(result.shown[0].issue == usage)
        #expect(result.shown[0].origin == .auto)
    }

    @Test func aClosingReferenceJoinsTheIssueAndASharedPullRequestJoinsTwoSessions() {
        let closing = form([session("a", typed: [usage]), session("b", age: 60, repository: "acme/web", closing: [usage])])
        #expect(closing.shown.map(\.sessionIDs) == [["a", "b"]])

        let shared = form([session("a", pullRequests: [rounding]), session("b", age: 60, repository: "acme/web", pullRequests: [rounding])])
        #expect(shared.shown.map(\.sessionIDs) == [["a", "b"]])
        #expect(shared.shown[0].issue == nil)
    }

    @Test func aLoneSessionFormsATaskOnlyWhenItSpansTwoRepositories() {
        #expect(form([session("a", pullRequests: [rounding])]).state.tasks.isEmpty)
        #expect(form([session("a", extraRepositories: ["acme/web"], pullRequests: [rounding])]).shown.map(\.sessionIDs) == [["a"]])
    }

    @Test func threeLinkedPullRequestsInOneRepositoryAreNotASweep() {
        let linked = (1...3).map { PullRequestLink(repository: "acme/billing", number: $0) }
        let result = form([session("a", pullRequests: linked), session("b", age: 60, repository: "acme/web", pullRequests: [linked[1]])])
        #expect(result.shown.map(\.sessionIDs) == [["a", "b"]])
    }

    @Test func aSweepContributesNothingButStaysInItsTask() {
        let pullRequests = (1...6).map { PullRequestLink(repository: "acme/billing", number: $0) }
        let sweep = session("sweep", age: 10, typed: [usage], pullRequests: pullRequests)
        #expect(form([session("a", typed: [usage]), session("b", age: 60, typed: [usage]), sweep]).shown.map(\.sessionIDs) == [["a", "b"]])

        let manyIssues = (1...4).map { IssueRef(repository: "acme/billing", number: $0) }
        #expect(form([session("x", typed: manyIssues), session("y", age: 60, typed: manyIssues)]).shown.isEmpty)

        let stored = TaskState(tasks: [StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "sweep"])])
        #expect(form([session("a", typed: [usage]), sweep], from: stored).shown.map(\.sessionIDs) == [["a", "sweep"]])

        let holding = TaskState(tasks: [StoredTask(id: "t", origin: .auto, sessionIDs: ["a", "b"])])
        let pair = [session("a", pullRequests: [rounding]), session("b", age: 1, pullRequests: [rounding])]
        #expect(form(pair + [session("sweep", age: 2, typed: [usage], pullRequests: [rounding] + pullRequests)], from: holding).state.tasks.map(\.sessionIDs) == [["a", "b"]])
    }

    @Test func aJoinSurvivesTheEvidenceRollingOut() {
        let stored = TaskState(tasks: [StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "b"])])
        let result = form([session("a"), session("b", age: 60, repository: "acme/web")], from: stored)
        #expect(result.shown.map(\.sessionIDs) == [["a", "b"]])
        #expect(result.state.tasks[0].issue == usage)
    }

    @Test func oneTaskPerSessionTheFirstNamedIssueWinsAndAConflictLeavesItAlone() {
        let stored = TaskState(tasks: [
            StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "b"]),
            StoredTask(id: "u", issue: web, origin: .auto, sessionIDs: ["c", "d"]),
        ])
        let members = [session("a"), session("b", age: 1), session("c", age: 2), session("d", age: 3)]
        let later = form(members + [session("e", age: 4, typed: [usage]), session("f", age: 5, typed: [web, usage])], from: stored)
        #expect(later.state.tasks.map(\.sessionIDs) == [["a", "b", "e"], ["c", "d", "f"]])

        let conflicting = [session("a"), session("b", age: 1), session("c", age: 2, pullRequests: [rounding]), session("d", age: 3), session("e", age: 4, typed: [usage], pullRequests: [rounding])]
        #expect(form(conflicting, from: stored).state.tasks.map(\.sessionIDs) == [["a", "b"], ["c", "d"]])
    }

    @Test func aRemovedSessionStaysRemovedWhateverItsEvidence() {
        var state = TaskState(tasks: [StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "b", "c"])])
        state.remove("c", from: "t")
        let spanning = [session("a", typed: [usage]), session("b", age: 1, typed: [usage]), session("c", age: 2, extraRepositories: ["acme/web"], typed: [usage])]
        #expect(form(spanning, from: state).state.tasks.map(\.sessionIDs) == [["a", "b"]])
        #expect(form(spanning, from: state).state.tasks[0].excluded == ["c"])

        var shrunk = TaskState(tasks: [StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "b", "c"])])
        shrunk.remove("a", from: "t")
        shrunk.remove("b", from: "t")
        let plain = [session("a", typed: [usage]), session("b", age: 1, typed: [usage]), session("c", age: 2, typed: [usage])]
        let afterwards = form(plain, from: shrunk)
        #expect(afterwards.shown.isEmpty)
        #expect(afterwards.state.tasks.map(\.sessionIDs) == [["c"]])
        #expect(form(plain, from: afterwards.state).shown.isEmpty)
    }

    @Test func aRemovedSessionMayJoinADifferentTask() {
        var state = TaskState(tasks: [
            StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "b"]),
            StoredTask(id: "u", issue: web, origin: .auto, sessionIDs: ["c", "d"]),
        ])
        state.remove("a", from: "t")
        let sessions = [session("a", typed: [usage, web]), session("b", age: 1), session("c", age: 2), session("d", age: 3)]
        #expect(form(sessions, from: state).state.tasks.map(\.sessionIDs) == [["b"], ["c", "d", "a"]])
    }

    @Test func aDeletedAutoTaskDoesNotReformButADeletedLocalOneLeavesNoMark() {
        var state = TaskState(tasks: [StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "b"]), StoredTask(id: "l", origin: .local, sessionIDs: ["c"])])
        state.delete("t", dismissing: [rounding.key])
        state.delete("l", dismissing: ["pr:x"])
        #expect(state.tasks.isEmpty)
        #expect(state.dismissed == [usage.key, rounding.key])
        let sessions = [session("a", typed: [usage], pullRequests: [rounding]), session("b", age: 1, typed: [usage]), session("d", age: 2, pullRequests: [rounding])]
        #expect(form(sessions, from: state).state.tasks.isEmpty)
    }

    @Test func renamedAndLocalTasksSurviveWithOneSessionButAnUnnamedAutoOneDoesNot() {
        let stored = TaskState(tasks: [
            StoredTask(id: "named", name: "Invoices", origin: .auto, sessionIDs: ["a"]),
            StoredTask(id: "local", origin: .local, sessionIDs: ["b"]),
            StoredTask(id: "bare", origin: .auto, sessionIDs: ["c"]),
            StoredTask(id: "gone", name: "Gone", origin: .auto, sessionIDs: ["zzz"]),
        ])
        let result = form([session("a"), session("b", age: 1), session("c", age: 2)], from: stored)
        #expect(result.state.tasks.map(\.id) == ["named", "local"])
        #expect(result.shown.map(\.id) == ["named", "local"])
    }

    @Test func manualJoinsMoveASessionAndClearItsExclusion() {
        var state = TaskState(tasks: [StoredTask(id: "t", origin: .auto, sessionIDs: ["a", "b"]), StoredTask(id: "u", origin: .auto, sessionIDs: ["c"], excluded: ["a"])])
        state.join(["a"], to: "u")
        #expect(state.tasks.map(\.sessionIDs) == [["b"], ["c", "a"]])
        #expect(state.tasks[1].excluded.isEmpty)
        state.makeTask(["b", "c"], origin: .local)
        #expect(state.tasks.map(\.sessionIDs) == [[], ["a"], ["b", "c"]])
        state.continuing(["a": "c"])
        #expect(state.tasks.map(\.sessionIDs) == [[], ["c"], ["b", "c"]])
    }

    @Test func aTaskGainsAnIssueWhenALaterLookupNamesIt() {
        let before = form([session("a", pullRequests: [rounding]), session("b", age: 1, pullRequests: [rounding])])
        #expect(before.state.tasks[0].issue == nil)
        let after = form([session("a", closing: [usage], pullRequests: [rounding]), session("b", age: 1, pullRequests: [rounding])], from: before.state)
        #expect(after.state.tasks.map(\.id) == before.state.tasks.map(\.id))
        #expect(after.state.tasks[0].issue == usage)
    }

    @Test func aSharedBranchNameSuggestsAndNeverJoins() {
        let stored = TaskState(tasks: [StoredTask(id: "t", issue: usage, origin: .auto, sessionIDs: ["a", "b"])])
        let sessions = [session("a", typed: [usage], branches: ["usage-export"]), session("b", age: 1), session("c", age: 2, repository: "acme/web", branches: ["usage-export", "main"])]
        let join = form(sessions, from: stored)
        #expect(join.suggestions == [TaskSuggestion(key: "branch:usage-export", taskID: "t", sessionIDs: ["c"])])
        #expect(join.state.tasks[0].sessionIDs == ["a", "b"])

        let make = form([session("x", branches: ["usage-export"]), session("y", age: 1, repository: "acme/web", branches: ["usage-export"])])
        #expect(make.suggestions == [TaskSuggestion(key: "branch:usage-export", taskID: nil, sessionIDs: ["x", "y"])])
        #expect(make.state.tasks.isEmpty)
    }

    @Test func branchSuggestionsNeedTwoRepositoriesAndSkipDefaultsSweepsDismissedAndExcluded() {
        #expect(form([session("x", branches: ["usage-export"]), session("y", age: 1, branches: ["usage-export"])]).suggestions.isEmpty)
        #expect(form([session("x", branches: ["main"]), session("y", age: 1, repository: "acme/web", branches: ["main"])]).suggestions.isEmpty)

        let sweep = (1...6).map { PullRequestLink(repository: "acme/billing", number: $0) }
        #expect(form([session("x", pullRequests: sweep, branches: ["feat"]), session("y", age: 1, repository: "acme/web", branches: ["feat"])]).suggestions.isEmpty)

        let dismissed = TaskState(dismissed: ["branch:feat"])
        #expect(form([session("x", branches: ["feat"]), session("y", age: 1, repository: "acme/web", branches: ["feat"])], from: dismissed).suggestions.isEmpty)

        let excluded = TaskState(tasks: [StoredTask(id: "t", origin: .auto, sessionIDs: ["a", "b"], excluded: ["y"])])
        #expect(form([session("a", branches: ["feat"]), session("b", age: 1), session("y", age: 2, repository: "acme/web", branches: ["feat"])], from: excluded).suggestions.isEmpty)
    }

    @Test func storageKeepsUnreadableTasksAndTheDismissedKeys() {
        let state = TaskState(tasks: [StoredTask(id: "t", name: "Invoices", issue: usage, origin: .auto, sessionIDs: ["a"], excluded: ["b"])], dismissed: ["branch:x"])
        let stored = TaskState.stored(state.storage(keeping: [#"{"id":"f","origin":"board","extra":[1]}"#]))
        #expect(stored.state == state)
        #expect(stored.unreadable == [#"{"extra":[1],"id":"f","origin":"board"}"#])
        #expect(TaskState.stored(nil).state == TaskState())
        #expect(TaskState.stored("nonsense").state == TaskState())
    }

    @Test func aTaskRowSitsWhereItsNewestMemberWould() {
        let sessions = ["a", "b", "c", "d"].map { SessionSummary(id: $0, cwd: "/x", title: $0, lastActivity: .now) }
        let task = SessionTask(id: "t", title: "T", issue: nil, sessions: [sessions[1], sessions[3]])
        #expect(SessionTask.entries(of: sessions, tasks: [task]) == [.session("a"), .task("t"), .session("c")])
        #expect(SessionTask.entries(of: [sessions[3], sessions[0]], tasks: [task]) == [.session("a")])
    }

    @Test func aTaskWithALiveMemberGoesToActiveOnceAndLeavesTheBuckets() {
        let sessions = ["a", "b", "c", "d", "e"].map { SessionSummary(id: $0, cwd: "/x", title: $0, lastActivity: .now) }
        let live = SessionTask(id: "live", title: "L", issue: nil, sessions: [sessions[1], sessions[3]])
        let idle = SessionTask(id: "idle", title: "I", issue: nil, sessions: [sessions[2], sessions[4]])
        let liveIDs: Set = ["a", "d"]
        let liveSessions = [sessions[3], sessions[0], sessions[1]]
        #expect(SessionTask.activeEntries(of: liveSessions.filter { liveIDs.contains($0.id) }, tasks: [live, idle]) == [.task("live"), .session("a")])
        #expect(SessionTask.entries(of: sessions, tasks: [live, idle], liveIDs: liveIDs) == [.task("idle")])
    }
}
