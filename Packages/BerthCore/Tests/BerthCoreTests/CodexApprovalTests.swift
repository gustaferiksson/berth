@testable import BerthCore
import Foundation
import Testing

struct CodexApprovalTests {
    private let command = #"{"type":"custom_tool_call","call_id":"cmd","name":"exec","input":"await tools.exec_command({cmd:\"printf \\\"hello world\\\"\", sandbox_permissions:\"require_escalated\", justification:\"Verify the greeting.\"})"}"#
    private let question = #"{"type":"function_call","call_id":"question","name":"request_user_input","arguments":"{\"questions\":[{\"header\":\"Color\",\"id\":\"color\",\"question\":\"Which color?\",\"options\":[{\"label\":\"Red\",\"description\":\"A warm color\"},{\"label\":\"Blue\",\"description\":\"A cool color\"}]}]}"}"#

    @Test func readsCommandAndPatchApprovals() throws {
        #expect(try read([command]) == .permission(tool: "Bash", target: #"printf "hello world""#, detail: "Verify the greeting.", edit: nil))
        let patch = #"{"type":"custom_tool_call","call_id":"patch","name":"apply_patch","input":"*** Begin Patch\n*** Add File: note.txt\n+hello\n*** End Patch"}"#
        #expect(try read([patch]) == .permission(tool: "apply_patch", target: "*** Begin Patch\n*** Add File: note.txt\n+hello\n*** End Patch", detail: nil, edit: nil))
        let script = #"{"type":"custom_tool_call","call_id":"patch-script","name":"exec","input":"tools.apply_patch(\"*** Begin Patch\\n*** End Patch\")"}"#
        let scriptedApproval = try read([script])
        #expect(scriptedApproval == .permission(tool: "apply_patch", target: "*** Begin Patch\n*** End Patch", detail: nil, edit: nil))
        let shell = #"{"type":"function_call","call_id":"shell","name":"exec_command","arguments":"{\"cmd\":\"pwd\",\"justification\":\"Check the directory.\"}"}"#
        #expect(try read([shell]) == .permission(tool: "Bash", target: "pwd", detail: "Check the directory.", edit: nil))
    }

    @Test func readsOneQuestionAndRejectsUnsupportedShapes() throws {
        #expect(try read([question]) == .question("Which color?", [
            .init(label: "Red", detail: "A warm color"),
            .init(label: "Blue", detail: "A cool color"),
        ]))
        let multi = #"{"type":"function_call","call_id":"multi","name":"request_user_input","arguments":"{\"questions\":[{\"question\":\"A\",\"options\":[]},{\"question\":\"B\",\"options\":[]}]}"}"#
        #expect(try read([multi]) == .unrepresentable)
    }

    @Test func skipsAnsweredCallsAndStopsAtTheLatestUnrecognizedCall() throws {
        let output = #"{"type":"custom_tool_call_output","call_id":"cmd","output":"done"}"#
        let answer = #"{"type":"function_call_output","call_id":"question","output":{"answers":{"color":{"answers":["Blue"]}}}}"#
        let unknown = #"{"type":"function_call","call_id":"wait","name":"wait_agent","arguments":"{}"}"#
        let complete = #"{"timestamp":"2026-01-02T10:00:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#
        #expect(try read([command, output, question, answer]) == nil)
        #expect(try read([command, unknown]) == nil)
        #expect(try read([command], ending: complete) == nil)
        #expect(try read([question, command, output]) != nil)
    }

    private func read(_ items: [String], ending: String = "") throws -> PendingApproval? {
        let url = FileManager.default.temporaryDirectory.appending(path: "codex-approval-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = items.map { #"{"timestamp":"2026-01-02T10:00:00.000Z","type":"response_item","payload":\#($0)}"# }
        try (lines.joined(separator: "\n") + "\n" + ending + "\n").write(to: url, atomically: true, encoding: .utf8)
        return Harness.codex.readApproval?(url)
    }
}
