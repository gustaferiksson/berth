@testable import BerthCore
import Foundation
import Testing

struct ConversationApprovalTests {
    private func call(_ name: String, input: String, command: String? = nil, filePath: String? = nil, oldText: String? = nil, newText: String? = nil) -> ToolCall {
        ToolCall(use: RemoteEntry(id: "u", kind: .toolUse, text: input, name: name, command: command, filePath: filePath, oldText: oldText, newText: newText), result: nil)
    }

    private func live(_ json: String) throws -> LiveSession {
        try JSONDecoder().decode(LiveSession.self, from: Data(json.utf8))
    }

    @Test func unknownWaitingForNeedsTheTerminal() {
        #expect(PendingApproval.resolve(waitingFor: "dialog", call: call("Bash", input: "{}", command: "ls")) == .unrepresentable)
        #expect(PendingApproval.resolve(waitingFor: nil, call: nil) == .unrepresentable)
    }

    @Test func permissionWithoutACallYetIsLoading() {
        #expect(PendingApproval.resolve(waitingFor: "permission prompt", call: nil) == .loading)
    }

    @Test func commandAndEditTargets() {
        #expect(PendingApproval.resolve(waitingFor: "permission prompt", call: call("Bash", input: "{}", command: "rm -rf build")) == .permission(tool: "Bash", target: "rm -rf build", detail: nil, edit: nil))
        let edit = PendingApproval.resolve(waitingFor: "permission prompt", call: call("Edit", input: "{}", filePath: "/a.swift", oldText: "x", newText: "y"))
        #expect(edit == .permission(tool: "Edit", target: "/a.swift", detail: nil, edit: .init(old: "x", new: "y")))
    }

    @Test func singleChoiceQuestionMapsToOptions() {
        let input = #"{"questions":[{"question":"Which?","options":[{"label":"A","description":"first"},{"label":"B"}]}]}"#
        #expect(PendingApproval.resolve(waitingFor: "permission prompt", call: call("AskUserQuestion", input: input)) == .question("Which?", [.init(label: "A", detail: "first"), .init(label: "B", detail: nil)]))
    }

    @Test func multiSelectAndManyQuestionsNeedTheTerminal() {
        let multi = #"{"questions":[{"question":"Which?","multiSelect":true,"options":[{"label":"A"}]}]}"#
        let two = #"{"questions":[{"question":"1","options":[{"label":"A"}]},{"question":"2","options":[{"label":"B"}]}]}"#
        #expect(PendingApproval.resolve(waitingFor: "permission prompt", call: call("AskUserQuestion", input: multi)) == .unrepresentable)
        #expect(PendingApproval.resolve(waitingFor: "permission prompt", call: call("AskUserQuestion", input: two)) == .unrepresentable)
    }

    @Test func planIsTheExitPlanModeInput() {
        #expect(PendingApproval.resolve(waitingFor: "permission prompt", call: call("ExitPlanMode", input: ###"{"plan":"## Steps"}"###)) == .plan("## Steps"))
    }

    @Test func fallbackRules() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let waiting = { (waitingFor: String, ago: Double) in try live("{\"pid\":1,\"sessionId\":\"s\",\"cwd\":\"/\",\"status\":\"waiting\",\"waitingFor\":\"\(waitingFor)\",\"statusUpdatedAt\":\(Int((now.timeIntervalSince1970 - ago) * 1000))}") }
        #expect(ConversationFallback.needsTerminal(live: nil, approval: nil, tabAge: 3, now: now) == false)
        #expect(ConversationFallback.needsTerminal(live: nil, approval: nil, tabAge: 11, now: now))
        #expect(try ConversationFallback.needsTerminal(live: waiting("something else", 0), approval: .unrepresentable, tabAge: 99, now: now))
        #expect(try ConversationFallback.needsTerminal(live: waiting("permission prompt", 1), approval: .loading, tabAge: 99, now: now) == false)
        #expect(try ConversationFallback.needsTerminal(live: waiting("permission prompt", 6), approval: .loading, tabAge: 99, now: now))
        #expect(try ConversationFallback.needsTerminal(live: waiting("permission prompt", 6), approval: .permission(tool: "Bash", target: "ls", detail: nil, edit: nil), tabAge: 99, now: now) == false)
        #expect(try ConversationFallback.canLeaveTerminal(live: waiting("x", 0)) == false)
        #expect(try ConversationFallback.canLeaveTerminal(live: live(#"{"pid":1,"sessionId":"s","cwd":"/","status":"idle"}"#)))
        #expect(ConversationFallback.canLeaveTerminal(live: nil) == false)
    }
}
