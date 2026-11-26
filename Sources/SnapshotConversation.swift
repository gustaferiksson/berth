#if DEBUG
import AppKit
import BerthCore
import Foundation
import GhosttyTerminal

@MainActor
enum ConversationProbe {
    static var statusRowTop: CGFloat?
}

extension Snapshot {
    static let conversationFolder = "/private/tmp/berth-conversation-fixture"
    static let conversationSession = "conversation-fixture"

    private static let codexConversationSession = "5b34c260-0c36-4721-bcfa-d56c78a9ce31"
    private static let codexConversationChild = "e6883ec6-0344-4bec-8511-cf586a4e2efc"
    private static var showsEmptyConversation: Bool { UserDefaults.standard.bool(forKey: "snapshotConversationEmpty") }
    private static var showsLongCode: Bool { UserDefaults.standard.bool(forKey: "snapshotConversationLongCode") }
    private static var showsCodexApproval: Bool { UserDefaults.standard.bool(forKey: "snapshotConversationCodexApproval") }
    private static var showsCodexTasks: Bool { UserDefaults.standard.bool(forKey: "snapshotConversationCodexTasks") }
    private static var showsSlashCommands: Bool { UserDefaults.standard.bool(forKey: "snapshotConversationSlashCommands") }
    private static var showsShellCompletions: Bool { UserDefaults.standard.bool(forKey: "snapshotConversationShellCompletions") }

    private nonisolated(unsafe) static var tineStub: TineStubServer?
    private static var usesCodexConversation: Bool {
        showsCodexApproval || showsCodexTasks || UserDefaults.standard.string(forKey: "snapshotConversationAgent") == "codex"
    }

    private static var conversationStart: Date { Date.now.addingTimeInterval(-420) }

    private static func startTineStub() {
        guard !UserDefaults.standard.bool(forKey: "snapshotTineReal") else {
            let socket = (getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? "") + "/.local/share/tine/tine.sock"
            UserDefaults.standard.register(defaults: ["snapshotTineSocket": socket, ConversationShellCompleter.enabledKey: true])
            return
        }

        let items = [
            ("checkout", "Switch branches or restore working tree files", "subcommand", false, "checkout "),
            ("cherry-pick", "Apply the changes from existing commits", "subcommand", false, "cherry-pick "),
            ("clean", "Remove untracked files from the working tree", "subcommand", true, "clean "),
            ("changelog.md", "", "file", false, "changelog.md "),
            ("git checkout main", "", "history", false, "git checkout main "),
        ]
        let json = items.map { name, description, kind, dangerous, text in
            #"{"name":"\#(name)","description":"\#(description)","kind":"\#(kind)","dangerous":\#(dangerous),"matches":[0,1],"edit":{"start":4,"end":6,"text":"\#(text)","cursor":\#(4 + text.utf16.count)}}"#
        }
        let path = "/tmp/berth-tine-\(ProcessInfo.processInfo.processIdentifier).sock"
        let stub = TineStubServer(path: path) { _ in #"{"version":1,"pending":false,"items":[\#(json.joined(separator: ","))]}"# }
        do { try stub.start() } catch {
            FileHandle.standardError.write(Data("snapshot: could not start the fake tine socket: \(error)\n".utf8))
            exit(1)
        }

        tineStub = stub
        UserDefaults.standard.register(defaults: ["snapshotTineSocket": path, ConversationShellCompleter.enabledKey: true])
    }

    static var heavyConversationTurns: Int { UserDefaults.standard.integer(forKey: "snapshotConversationHeavy") }

    static var conversationTranscript: URL {
        let slug = conversationFolder.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        return Store.claudeDirectory.appending(path: "projects/\(slug)/\(conversationSession).jsonl")
    }

    static func seedConversationFixture() {
        guard UserDefaults.standard.bool(forKey: "snapshotConversation") else { return }
        guard let fixtureHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !fixtureHome.isEmpty else {
            FileHandle.standardError.write(Data("snapshot: -snapshotConversation needs CFFIXED_USER_HOME pointing at an empty fixture home\n".utf8))
            exit(1)
        }

        try? FileManager.default.createDirectory(atPath: conversationFolder, withIntermediateDirectories: true)
        if usesCodexConversation {
            guard UserDefaults.standard.bool(forKey: "codexEnabled"),
                  Store.codexDirectory.resolvingSymlinksInPath().path == URL(filePath: fixtureHome).appending(path: ".codex").resolvingSymlinksInPath().path
            else {
                FileHandle.standardError.write(Data("snapshot: Codex conversation fixtures require -codexEnabled YES and the fixture home’s CODEX_HOME\n".utf8))
                exit(1)
            }

            seedCodexConversationFixture()
            return
        }
        let transcript = conversationTranscript
        let directory = transcript.deletingLastPathComponent()
        if showsSlashCommands {
            let commands = URL(filePath: fixtureHome).appending(path: ".claude/commands")
            try? FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
            try? "---\ndescription: Compare two ledger exports\n---\nCompare the totals in both reports.".write(to: commands.appending(path: "compare-exports.md"), atomically: true, encoding: .utf8)
        }
        if showsShellCompletions { startTineStub() }
        if heavyConversationTurns > 0 {
            guard Store.claudeDirectory.resolvingSymlinksInPath().path == URL(filePath: fixtureHome).appending(path: ".claude").resolvingSymlinksInPath().path else {
                conversationPerfFailure("heavy fixture requires the fixture home's .claude directory")
            }

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try heavyConversationFixture(turns: heavyConversationTurns)
                try data.write(to: transcript, options: .atomic)
                print("perf conversation fixture: generated \(heavyConversationTurns) turns, \(data.count) bytes")
            } catch {
                conversationPerfFailure("could not seed fixture: \(error)")
            }
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effort = UserDefaults.standard.string(forKey: "snapshotConversationEffort").map { [#"{"type":"api-request","querySource":"repl_main_thread","params":{"model":"claude-sonnet-4-5","output_config":{"effort":"\#($0)"}}}"#] } ?? []
        let mode = UserDefaults.standard.string(forKey: "snapshotConversationMode") ?? "auto"
        let records = showsEmptyConversation ? [] : conversationRecords()
        var lines = effort + [#"{"type":"permission-mode","permissionMode":"\#(mode)","sessionId":"\#(conversationSession)"}"#] + records.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self) }
        if showsWatching, !showsEmptyConversation {
            let timestamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            lines.append(#"{"type":"user","uuid":"steward-fixture","sessionId":"\#(conversationSession)","cwd":"\#(conversationFolder)","timestamp":"\#(timestamp)","message":{"role":"user","content":"<command-name>/steward</command-name>\n<command-args>https://github.com/acme/billing/pull/4821</command-args>"}}"#)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        guard !showsEmptyConversation else { return }

        let subagents = directory.appending(path: "\(conversationSession)/subagents")
        try? FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let subagentLines = [
            #"{"type":"user","uuid":"docs-prompt","isSidechain":true,"timestamp":"\#(conversationStart.addingTimeInterval(280).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))","message":{"role":"user","content":"Review docs/columns.md for the new plan name column."}}"#,
            #"{"type":"assistant","uuid":"docs-read","isSidechain":true,"timestamp":"\#(conversationStart.addingTimeInterval(283).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))","message":{"content":[{"type":"tool_use","id":"docs-read","name":"Read","input":{"file_path":"/fixture/docs/columns.md"}}]}}"#,
            #"{"type":"user","uuid":"docs-result","isSidechain":true,"timestamp":"\#(conversationStart.addingTimeInterval(285).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))","message":{"content":[{"type":"tool_result","tool_use_id":"docs-read","content":"Export columns\nDate, Amount"}]}}"#,
            #"{"type":"assistant","uuid":"docs-reply","isSidechain":true,"timestamp":"\#(conversationStart.addingTimeInterval(290).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))","message":{"content":[{"type":"text","text":"The column list needs **Plan name** after Amount. I’m also checking the CSV header example."}]}}"#,
        ]
        try? (subagentLines.joined(separator: "\n") + "\n").write(to: subagents.appending(path: "agent-agent-docs.jsonl"), atomically: true, encoding: .utf8)
        try? #"{"agentType":"general-purpose","description":"Review the docs for the export column","toolUseId":"t8"}"#.write(to: subagents.appending(path: "agent-agent-docs.meta.json"), atomically: true, encoding: .utf8)
    }

    static func conversationRecord(id: String, type: String, date: Date, blocks: [[String: Any]]) throws -> Data {
        let message: [String: Any] = ["role": type, "id": "msg-\(id)", "content": blocks, "model": "claude-sonnet-4-5"]
        let record: [String: Any] = [
            "type": type, "uuid": id, "timestamp": date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "sessionId": conversationSession, "cwd": conversationFolder, "gitBranch": "fixture-ledger", "message": message,
        ]
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(10)
        return line
    }

    private static func heavyConversationFixture(turns: Int) throws -> Data {
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": fixtureImage(format: .jpeg).base64EncodedString()]]
        let finished = Date.now.addingTimeInterval(-30)
        var data = Data()
        for turn in 1...turns {
            let id = "heavy-\(turn)"
            let start = finished.addingTimeInterval(-Double(turns - turn + 1) * 45)
            var prompt: [[String: Any]] = [["type": "text", "text": "Check the invented ledger export for batch \(turn) and show the Swift, Python and JSON examples."]]
            if (turns - turn).isMultiple(of: 6), turns - turn < 18 { prompt.append(image) }
            try data.append(conversationRecord(id: "\(id)-prompt", type: "user", date: start, blocks: prompt))
            for index in 0..<(5 + turn % 11) {
                let call = "\(id)-tool-\(index)"
                let (name, input, output) = heavyConversationTool(turn: turn, index: index)
                let date = start.addingTimeInterval(Double(2 * index + 1))
                try data.append(conversationRecord(id: call, type: "assistant", date: date, blocks: [["type": "tool_use", "id": call, "name": name, "input": input]]))
                try data.append(conversationRecord(id: "\(call)-result", type: "user", date: date.addingTimeInterval(1), blocks: [["type": "tool_result", "tool_use_id": call, "content": output]]))
            }
            try data.append(conversationRecord(id: "\(id)-reply", type: "assistant", date: start.addingTimeInterval(35), blocks: [["type": "text", "text": heavyConversationReply(turn: turn)]]))
        }
        return data
    }

    private static func heavyConversationTool(turn: Int, index: Int) -> (String, [String: String], String) {
        let file = "\(conversationFolder)/Sources/Batch\(turn)/Ledger\(index).swift"
        switch index % 4 {
        case 0: return ("Read", ["file_path": file], (1...12).map { "\($0)\tlet row\($0) = ledger.rows[\($0 - 1)]" }.joined(separator: "\n"))
        case 1: return ("Edit", ["file_path": file, "old_string": "let rows = ledger.rows", "new_string": "let rows = ledger.rows.sorted(by: byDate)"], "Updated the row order in \(file).")
        case 2: return ("Bash", ["command": "swift test --filter LedgerBatch\(turn)Tests", "description": "Verify the export"], "Building fixtures…\nTest Case 'testBatch\(turn)' passed\nExecuted 12 tests, with 0 failures.")
        default: return ("Grep", ["pattern": "ledger.rows", "path": "Sources/Batch\(turn)"], "\(file):12:let rows = ledger.rows")
        }
    }

    static func heavyConversationReply(turn: Int) -> String {
        let swift = (1...28).map { "    static let row\($0) = \(turn * 10 + $0)" }.joined(separator: "\n")
        let python = (1...24).map { "    rows.append((\($0), amount + \($0)))" }.joined(separator: "\n")
        let json = (1...20).map { "  \"row_\($0)\": \(turn + $0)\($0 == 20 ? "" : ",")" }.joined(separator: "\n")
        return """
        ## Ledger batch \(turn)

        I checked the **daily ledger export** against the sample input. The formatter can use a fixed date boundary and keep each `batch_id` intact through the conversion. An empty ledger still produces the header so downstream readers have a stable schema.

        The parser reads amounts as decimals before sorting the rows by date. Tied dates retain their input order, which makes each run reproducible. The examples use invented row values so they can be checked without a database.

        When you fold the totals by day, keep the original currency code on every row. That lets a reader distinguish a missing value from a zero amount and avoids silently mixing two currencies into the same total.

        ### Verification

        - Preserve the **input row count** and retain the first record's date.
        - Round once, after accumulating the daily sum.
        - Keep the JSON keys stable for export consumers.

        | Check | Input | Result |
        | --- | --- | --- |
        | Ordering | Dates with ties | Stable |
        | Empty export | Zero rows | Header only |
        | Precision | Decimal amounts | Exact |

        ```swift
        struct Batch\(turn) {
        \(swift)
        }
        ```

        ```python
        def export_rows(amount):
            rows = []
        \(python)
            return rows
        ```

        ```json
        {
        \(json)
        }
        ```

        The last fixture confirms the same totals in both implementations. Record the batch number alongside the export so a later check can find the exact input.
        """
    }

    private static func seedCodexConversationFixture() {
        let directory = Store.codexDirectory.appending(path: "sessions/2026/01/02")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let metadata: [(String, String)] = [
            ("session_meta", #"{"id":"\#(codexConversationSession)","cwd":"\#(conversationFolder)","timestamp":"\#(timestamp)","originator":"codex-tui","thread_source":"user"}"#),
            ("turn_context", #"{"cwd":"\#(conversationFolder)","model":"gpt-test","effort":"high"}"#),
        ]
        let payloads: [(String, String)] = [
            ("event_msg", #"{"type":"task_started"}"#),
            ("event_msg", #"{"type":"user_message","message":"Fix the usage export and add a plan name column."}"#),
            ("event_msg", #"{"type":"agent_message","phase":"commentary","message":"I'll check the export tests, then update the formatter and column list."}"#),
            ("response_item", #"{"type":"function_call","call_id":"fixture-exec","name":"exec_command","arguments":"{\"cmd\":\"swift test --filter ExportTests\"}"}"#),
            ("response_item", #"{"type":"function_call_output","call_id":"fixture-exec","output":"Chunk ID: fixture\nWall time: 0.4 seconds\nProcess exited with code 0\nOutput:\nExecuted 2 tests, with 0 failures\nhttps://github.com/example/usage/pull/42"}"#),
            ("event_msg", #"{"type":"patch_apply_end","call_id":"fixture-patch","success":true,"changes":{"Sources/Export.swift":{"type":"update","unified_diff":"@@ -1 +1,2 @@\n let formatter = DateFormatter()\n+formatter.timeZone = TimeZone(identifier: \"Europe/Stockholm\")"},"docs/columns.md":{"type":"add","content":"Columns\nDate, Amount, Plan name\n"}}}"#),
            ("event_msg", #"{"type":"web_search_end","call_id":"fixture-search","query":"DateFormatter timeZone","results":[{"title":"DateFormatter","url":"https://developer.apple.com/documentation/foundation/dateformatter"}]}"#),
            ("response_item", #"{"type":"function_call","call_id":"fixture-plan","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Fix the export and document the column\",\"status\":\"completed\"}]}"}"#),
            ("response_item", #"{"type":"function_call_output","call_id":"fixture-plan","output":"Plan updated"}"#),
            ("event_msg", #"{"type":"agent_message","phase":"final","message":"Fixed the export time zone and added the plan name column. Both export tests pass.\n\nThe column list is in `docs/columns.md`."}"#),
            ("event_msg", #"{"type":"token_count","info":{"last_token_usage":{"input_tokens":61000},"model_context_window":258400}}"#),
        ]
        let tail: [(String, String)]
        if showsEmptyConversation {
            tail = []
        } else if showsCodexApproval {
            tail = [
                ("event_msg", #"{"type":"item_completed","item":{"type":"AgentMessage","id":"fixture-note","content":[{"type":"text","text":"I’ll run the export verification script next."}]}}"#),
                ("response_item", #"{"type":"custom_tool_call","call_id":"fixture-approval","name":"exec","input":"await tools.exec_command({cmd:\"./scripts/check-export.sh\", sandbox_permissions:\"require_escalated\", justification:\"Run the export verification script against the generated fixture.\"})"}"#),
            ]
        } else if showsCodexTasks {
            tail = [
                ("response_item", #"{"type":"function_call","name":"spawn_agent","call_id":"fixture-agent","arguments":"{\"task_name\":\"docs\",\"message\":\"Check the export documentation\"}"}"#),
                ("event_msg", #"{"type":"item_completed","item":{"type":"SubAgentActivity","kind":"started","id":"fixture-agent","agent_thread_id":"\#(codexConversationChild)","agent_path":"/root/docs"}}"#),
                ("response_item", #"{"type":"function_call_output","call_id":"fixture-agent","output":"Started docs agent"}"#),
                ("event_msg", #"{"type":"task_complete"}"#),
            ]
            let child = [
                #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(codexConversationChild)","thread_source":"subagent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(codexConversationSession)","agent_path":"/root/docs","agent_role":"Reviewer"}}}}}"#,
                #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started"}}"#,
                #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"user_message","message":"Check the export documentation."}}"#,
                #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"agent_message","message":"I’m reviewing the CSV examples."}}"#,
            ]
            try? (child.joined(separator: "\n") + "\n").write(to: directory.appending(path: "rollout-2026-01-02T10-01-00-\(codexConversationChild).jsonl"), atomically: true, encoding: .utf8)
        } else {
            tail = (UserDefaults.standard.string(forKey: "snapshotConversationStatus") ?? "busy") == "busy" ? [] : [("event_msg", #"{"type":"task_complete"}"#)]
        }
        let now = Date.now
        let records = metadata + (showsEmptyConversation ? [] : payloads + tail)
        let lines = records.enumerated().map { index, record in
            let date = now.addingTimeInterval(Double(min(index - metadata.count - payloads.count + 2, 0))).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            return #"{"timestamp":"\#(date)","type":"\#(record.0)","payload":\#(record.1)}"#
        }
        let url = directory.appending(path: "rollout-2026-01-02T10-00-00-\(codexConversationSession).jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func conversationRecords() -> [[String: Any]] {
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var clock = conversationStart
        var count = 0
        let base = { (type: String, advance: TimeInterval, message: [String: Any]) -> [String: Any] in
            clock = clock.addingTimeInterval(advance)
            count += 1
            return ["type": type, "uuid": "fixture-\(count)", "timestamp": clock.formatted(format), "sessionId": conversationSession, "cwd": conversationFolder, "gitBranch": "usage-export", "message": message]
        }
        let prompt = { (text: String, advance: TimeInterval) in base("user", advance, ["role": "user", "content": text]) }
        let usage: [String: Any] = ["input_tokens": 3, "cache_read_input_tokens": 61_000, "cache_creation_input_tokens": 700, "output_tokens": 240]
        let assistant = { (advance: TimeInterval, blocks: [[String: Any]]) in base("assistant", advance, ["role": "assistant", "id": "msg-\(count)", "model": "claude-sonnet-4-5", "content": blocks, "usage": usage]) }
        let text = { (value: String) -> [String: Any] in ["type": "text", "text": value] }
        if showsLongCode {
            let input = (1...60).map { "export TZ_REGION_\($0)=Europe/Stockholm" }.joined(separator: "\n")
            let output = (1...40).map { "assert(exportedRows[\($0 - 1)].region == expectedRegion)" }.joined(separator: "\n")
            let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": fixtureImage().base64EncodedString()]]
            let split = base("user", 4, ["role": "user", "content": [text("Please get these in "), text("[Image #3]"), text(" the tables, and compare with "), text("[Image #4]"), image, image]])
            return [
                prompt("How can I verify the time zone for these ledger exports?\n\n```sh\n\(input)\n```", 0),
                assistant(2, [text("This Swift check verifies the region for each exported row.\n\n```swift\n\(output)\n```")]),
                split,
            ]
        }
        let use = { (id: String, name: String, input: [String: Any]) -> [String: Any] in ["type": "tool_use", "id": id, "name": name, "input": input] }
        let result = { (id: String, output: String, advance: TimeInterval, extra: [String: Any]) -> [String: Any] in
            var record = base("user", advance, ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": output]]])
            record.merge(extra) { $1 }
            return record
        }
        let virtual = { (record: [String: Any]) -> [String: Any] in record.merging(["isVirtual": true]) { $1 } }
        let file = "\(conversationFolder)/Sources/Export.swift"
        let start = clock
        let records = [
            prompt("Why does the usage export fail on CI? It passes locally.", 0),
            assistant(4, [text("I'll start with the export code and the CI log.")]),
            assistant(3, [use("t1", "Grep", ["pattern": "func exportRows", "path": "Sources"])]),
            result("t1", "Sources/Export.swift:12:func exportRows(for account: Account) throws -> [Row] {", 1, [:]),
            assistant(3, [use("t2", "Read", ["file_path": file])]),
            result("t2", (1...42).map { "\($0)\tline \($0) of the export" }.joined(separator: "\n"), 1, [:]),
            assistant(12, [text("The date formatter has no fixed time zone, so the CI runner (UTC) and your Mac (Stockholm) group rows into different days."), use("t3", "Edit", ["file_path": file, "old_string": "let formatter = DateFormatter()\nformatter.dateFormat = \"yyyy-MM-dd\"\nreturn rows.map { formatter.string(from: $0.date) }", "new_string": "let formatter = DateFormatter()\nformatter.dateFormat = \"yyyy-MM-dd\"\nformatter.timeZone = TimeZone(identifier: \"Europe/Stockholm\")\nreturn rows.map { formatter.string(from: $0.date) }"])]),
            result("t3", "The file \(file) has been updated.", 1, [:]),
            assistant(20, [use("t4", "Bash", ["command": "swift test --filter ExportTests", "description": "Run the export tests"])]),
            result("t4", "Building for debugging...\n[1/3] Compiling Export.swift\nTest Suite 'ExportTests' started\nTest Case 'testRowsGroupByDay' passed (0.004 seconds)\nTest Case 'testRowsCrossMidnight' passed (0.002 seconds)\nExecuted 2 tests, with 0 failures in 0.006 seconds", 38, [:]),
            assistant(40, [text("Fixed. The export grouped rows by the machine's time zone, so I pinned it.\n\n## What changed\n\n- `Export.swift` now sets `formatter.timeZone` to **Europe/Stockholm**\n- Both export tests pass\n- Nothing else reads the formatter\n\n```swift\nformatter.timeZone = TimeZone(identifier: \"Europe/Stockholm\")\n```\n\n```ts\nconst blank = (value: string | undefined) => value === undefined || value.trim().length === 0;\nexport function parseRows(fields: string[], values: Map<string, number>) {\n  const total = fields.filter((name) => !blank(name)).length;\n  return values.size === total ? \"ok\" : `mismatch ${total}`;\n}\n```\n\n| Machine | Zone | Result |\n| --- | --- | --- |\n| Mac | Stockholm | passes |\n| CI | UTC | passes now |")]),
            prompt("<bash-input>git log --oneline -8</bash-input>", 2),
            prompt("""
            <bash-stdout>a10b3f2 Pin export time zone
            1df038a Cover midnight boundary
            73c90de Group rows by export day
            b7f4a09 Document CSV columns
            04c2f18 Add export fixtures
            e8a012b Include account name
            659d3a0 Sort export rows
            2fd7408 Add usage export</bash-stdout>
            """, 1),
            prompt("<bash-input>ls missing-dir</bash-input>", 2),
            prompt("<bash-stderr>ls: missing-dir: No such file or directory</bash-stderr>", 1),
            prompt("<bash-input>cd /tmp && for i in 408 409 410 412 325; do gh issue close $i -R gustaferiksson/berth -r completed; done; gh pr close 381 -R gustaferiksson/berth; gh pr close 382 -R gustaferiksson/berth; gh api -X DELETE repos/gustaferiksson/berth/git/refs/heads/browser-read-access</bash-input>", 2),
            prompt("""
            <bash-stdout>Closed issue #408
            Closed issue #409
            Closed issue #410</bash-stdout><bash-stderr></bash-stderr>
            """, 1),
            base("user", 90, ["role": "user", "content": [["type": "text", "text": "Nice. Now add a plan name column, start the slow migration check in the background and have an agent review the docs. [Image #12] [Image #13]"], ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": fixtureImage().base64EncodedString()]], ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": fixtureImage().base64EncodedString()]]]]),
            assistant(5, [text("I'll add the column, then run both checks in parallel.")]),
            assistant(4, [use("t5", "Read", ["file_path": file])]),
            result("t5", (1...60).map { "\($0)\tline \($0)" }.joined(separator: "\n"), 1, [:]),
            assistant(15, [use("t6", "Edit", ["file_path": file, "old_string": "struct Row {\n    let date: Date\n    let amount: Decimal\n}", "new_string": "struct Row {\n    let date: Date\n    let amount: Decimal\n    let planName: String\n}"])]),
            result("t6", "The file \(file) has been updated.", 1, [:]),
            assistant(2, [use("t6b", "Edit", ["file_path": file, "old_string": "let rate = 1", "new_string": "let rate = 2"])]),
            result("t6b", "The file \(file) has been updated.", 1, [:]),
            assistant(6, [text("Column added. Starting the migration check and the docs review now."), use("t7", "Bash", ["command": "swift test --filter MigrationTests --parallel", "description": "Run the migration check in the background", "run_in_background": true])]),
            result("t7", "Command running in background with ID: bg-migration. Output is being written to: /private/tmp/bg-migration.output", 1, ["toolUseResult": ["backgroundTaskId": "bg-migration"]]),
            assistant(3, [use("t8", "Agent", ["description": "Review the docs for the export column", "subagent_type": "general-purpose", "prompt": "Read docs/columns.md and list what must change for the plan name column.", "run_in_background": true])]),
            result("t8", "Async agent launched successfully.\nagentId: agent-docs (internal ID, do not mention to user)", 1, ["toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "agent-docs", "description": "Review the docs for the export column"]]),
            assistant(4, [use("t10", "REPL", ["code": "await $`ls docs`", "description": "List the docs folder"])]),
            result("t10", "(dispatched #12)", 1, [:]),
            assistant(2, [use("t11", "Poll", [:])]),
            result("t11", "<system>authentic event nonces for this delivery: x</system>", 5, [:]),
            virtual(assistant(0, [use("repl_1", "Bash", ["command": "ls docs", "description": "List the docs folder"])])),
            virtual(result("repl_1", "", 0, ["toolUseResult": ["stdout": "columns.md\nexport.md", "stderr": "", "interrupted": false]])),
            virtual(assistant(0, [use("repl_2", "Read", ["file_path": "\(conversationFolder)/docs/columns.md"])])),
            virtual(result("repl_2", "", 0, ["toolUseResult": ["type": "text", "file": ["filePath": "\(conversationFolder)/docs/columns.md", "content": "# Columns\n\nplan name\n", "numLines": 3]]])),
            assistant(3, [text("The migration check is still running, the docs agent has started. Notes are in [the export docs](https://example.com/docs/export).")]),
            assistant(3, [use("t12", "SendMessage", ["to": "agent-docs", "message": "Also check the CSV header."])]),
            result("t12", "", 1, [:]),
            assistant(30, [use("t9", "Read", ["file_path": "\(conversationFolder)/docs/columns.md"])]),
        ] + pendingRecords(assistant: assistant, use: use, result: result) + queuedRecords(base: base) + imageOnlyRecords(base: base) + mentionRecords(base: base)
        let repetitions = UserDefaults.standard.integer(forKey: "snapshotConversationRepeat")
        guard repetitions > 1 else { return records }

        let duration = clock.timeIntervalSince(start) + 1
        return (0..<repetitions).flatMap { repetition in
            records.map { original in
                var record = original
                if let uuid = original["uuid"] as? String { record["uuid"] = "\(uuid)-r\(repetition)" }
                if let timestamp = original["timestamp"] as? String, let date = try? format.parse(timestamp) {
                    record["timestamp"] = date.addingTimeInterval(Double(repetition) * duration).formatted(format)
                }
                if var message = original["message"] as? [String: Any] {
                    if let id = message["id"] as? String { message["id"] = "\(id)-r\(repetition)" }
                    if let blocks = message["content"] as? [[String: Any]] {
                        message["content"] = blocks.filter { repetition == 0 || $0["type"] as? String != "image" }.map { original in
                            var block = original
                            if original["type"] as? String == "tool_use", let id = original["id"] as? String { block["id"] = "\(id)-r\(repetition)" }
                            if original["type"] as? String == "tool_result", let id = original["tool_use_id"] as? String { block["tool_use_id"] = "\(id)-r\(repetition)" }
                            return block
                        }
                    }
                    record["message"] = message
                }
                return record
            }
        }
    }

    private static func fixtureImage(format: NSBitmapImageRep.FileType = .png) -> Data {
        let image = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(in: rect, angle: 35)
            return true
        }
        return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: format, properties: [:]) } ?? Data()
    }

    private static func imageOnlyRecords(base: (String, TimeInterval, [String: Any]) -> [String: Any]) -> [[String: Any]] {
        guard UserDefaults.standard.bool(forKey: "snapshotConversationImageOnly") else { return [] }

        return [base("user", 1, ["role": "user", "content": [["type": "text", "text": "[Image #1]"], ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": fixtureImage().base64EncodedString()]]]])]
    }

    private static func mentionRecords(base: (String, TimeInterval, [String: Any]) -> [String: Any]) -> [[String: Any]] {
        guard let folder = UserDefaults.standard.string(forKey: "snapshotConversationMentions") else { return [] }

        let text = "@\(folder)/Screen Recording demo.mov break down this video, then compare @\(folder)/diagram.png with @\(folder)/notes.txt and @\(folder)/gone.pdf"
        return [base("user", 1, ["role": "user", "content": text])]
    }

    private static func queuedRecords(base: (String, TimeInterval, [String: Any]) -> [String: Any]) -> [[String: Any]] {
        guard let text = UserDefaults.standard.string(forKey: "snapshotConversationQueued") else { return [] }

        return [base("queue-operation", 1, [:]).merging(["operation": "enqueue", "content": text]) { $1 }]
    }

    private static func pendingRecords(assistant: (TimeInterval, [[String: Any]]) -> [String: Any], use: (String, String, [String: Any]) -> [String: Any], result: (String, String, TimeInterval, [String: Any]) -> [String: Any]) -> [[String: Any]] {
        let file = "\(conversationFolder)/Sources/Export.swift"
        let call: [String: Any]
        switch UserDefaults.standard.string(forKey: "snapshotConversationPending") ?? "" {
        case "bash": call = use("tp", "Bash", ["command": "rm -rf .build && swift build -c release 2>&1 | tail -20", "description": "Clean and rebuild in release mode"])
        case "edit": call = use("tp", "Edit", ["file_path": file, "old_string": "let formatter = DateFormatter()\nformatter.dateFormat = \"yyyy-MM-dd\"\nreturn rows.map { formatter.string(from: $0.date) }", "new_string": "let formatter = DateFormatter()\nformatter.dateFormat = \"yyyy-MM-dd\"\nformatter.timeZone = TimeZone(identifier: \"UTC\")\nreturn rows.map { formatter.string(from: $0.date) }"])
        case "question": call = use("tp", "AskUserQuestion", ["questions": [["question": "Which time zone should the export use?", "header": "Zone", "multiSelect": false, "options": [["label": "Europe/Stockholm", "description": "Matches the Mac the export is built on"], ["label": "UTC", "description": "Matches the CI runner"], ["label": "Per account", "description": "Read it from each account's settings"]]]]])
        case "plan": call = use("tp", "ExitPlanMode", ["plan": "## Plan\n\n1. Add a `planName` column to `Row`\n2. Fill it in `exportRows(for:)` from the account\n3. Update the CSV header and the two export tests\n\nNothing else reads `Row`, so the change stays inside `Export.swift` and `ExportTests.swift`.\n\n```swift\nlet planName: String\n```"])
        default: return []
        }
        return [result("t9", "1\tdocs", 1, [:]), assistant(2, [call])]
    }

    private static func fakeConversationLive(status: String, waitingFor: String?, updatedSecondsAgo: Double) -> LiveSession? {
        let started = Int(conversationStart.timeIntervalSince1970 * 1000) - 60_000
        let updated = Int((Date.now.timeIntervalSince1970 - updatedSecondsAgo) * 1000)
        let waiting = waitingFor.map { #","waitingFor":"\#($0)""# } ?? ""
        return try? JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":\#(getpid()),"sessionId":"\#(conversationSession)","cwd":"\#(conversationFolder)","status":"\#(status)"\#(waiting),"statusUpdatedAt":\#(updated),"startedAt":\#(started)}"#.utf8))
    }

    private static func driveConversation(_ script: String, store: Store, tab: Tab, rawLog: String?, save: (String) -> Void) async {
        var shown = store.liveBySession[conversationSession].map { (waitingFor: $0.waitingFor, since: $0.statusUpdatedAt) }
        let state = {
            let live = store.liveBySession[conversationSession]
            let model = store.conversationModels[tab.id]
            print("  state: status \(live?.status ?? "none") updated \(live?.statusUpdatedAt.map { Int($0) % 100_000 } ?? -1), waitingFor \(live?.waitingFor ?? "none"), shows conversation \(store.selectedShowsConversation), suspended \(store.conversationSuspended.contains(tab.id)), draft \(model?.draft.text.debugDescription ?? "-") files \(model?.draft.files.map(\.lastPathComponent) ?? []), notice \(model?.notice ?? "none")")
        }
        let log = {
            guard let rawLog, let data = FileManager.default.contents(atPath: rawLog) else { return print("  log: empty") }

            print("  log: \(data.map { $0 == 0x1B ? "ESC" : $0 == 0x0D ? "CR" : $0 < 0x20 ? "^\($0)" : String(UnicodeScalar($0)) }.joined(separator: " ").replacing("E S C", with: "ESC"))")
        }
        let steps = script.split(separator: "|").map(String.init)
        for (index, step) in steps.enumerated() {
            let (name, argument) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
            print("step \(step)")
            switch name {
            case "type": store.conversationModels[tab.id]?.draft.text = argument

            case "attach": store.conversationModels[tab.id]?.append([URL(fileURLWithPath: argument)])

            case "remove": store.conversationModels[tab.id]?.remove(URL(fileURLWithPath: argument))

            case "send": await store.conversationModels[tab.id]?.send()

            case "reviewComments":
                let comments = argument.split(separator: ";").enumerated().map { ReviewComment(id: "drive-\($0.offset)", path: "README.md", line: $0.offset + 1, endLine: $0.offset + 1, text: String($0.element), snippet: "") }
                let sent = await store.sendReviewPrompt(ReviewComment.prompt(for: comments, branch: "feature", base: "main"), sessionID: conversationSession, noticeIn: ReviewModel(folder: tab.folder))
                print("review comments sent \(sent), conversation shown \(store.selectedShowsConversation)")

            case "decline": if let model = store.conversationModels[tab.id] { Task { await model.decline(waitingFor: shown?.waitingFor, since: shown?.since) } }

            case "stop": store.conversationModels[tab.id]?.interrupt()

            case "allow": store.conversationModels[tab.id]?.answer(.digit1, waitingFor: shown?.waitingFor, since: shown?.since)

            case "deny": store.conversationModels[tab.id]?.answer(.escape, waitingFor: shown?.waitingFor, since: shown?.since)

            case "choose": store.conversationModels[tab.id]?.answer(RemoteKey(rawValue: "digit\(argument)") ?? .digit1, waitingFor: shown?.waitingFor, since: shown?.since)

            case "show": shown = store.liveBySession[conversationSession].map { (waitingFor: $0.waitingFor, since: $0.statusUpdatedAt) }

            case "status":
                let parts = argument.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                store.fakeLiveSessions = fakeConversationLive(status: parts[0], waitingFor: parts.count > 1 ? parts[1] : nil, updatedSecondsAgo: 20).map { [$0] } ?? []
                store.refreshLive()

            case "restamp":
                store.fakeLiveSessions = store.fakeLiveSessions.compactMap { fakeConversationLive(status: $0.status ?? "idle", waitingFor: $0.waitingFor, updatedSecondsAgo: 1) }
                store.refreshLive()

            case "drop":
                store.fakeLiveSessions = []
                store.refreshLive()

            case "snap":
                print("switch visibility at \(argument): toolbar button \(store.canShowConversation), footer \(store.selectedStatusBarIsReachable), suspended \(store.conversationSuspended.contains(tab.id))")
                save(".\(argument).png")

            case "preview":
                guard let model = store.conversationModels[tab.id], let prompt = model.turns.lazy.compactMap(\.prompt).first(where: { $0.images != nil }) else { break }

                if let data = await model.promptImage(entryID: prompt.id, index: 0) { ConversationImagePreview.shared.showOriginal(data) }

            case "log": log()

            case "enqueue", "dequeue", "reply":
                let operation: [String: Any] = name == "reply"
                    ? ["type": "assistant", "uuid": UUID().uuidString, "message": ["role": "assistant", "id": "msg-\(UUID().uuidString)", "model": "claude-sonnet-4-5", "content": [["type": "text", "text": argument]]]]
                    : ["type": "queue-operation", "operation": name, "content": argument]
                let record = operation.merging(["timestamp": Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), "sessionId": conversationSession, "cwd": conversationFolder]) { $1 }
                var lines = [record]
                if name == "dequeue" {
                    lines.append(["type": "user", "uuid": UUID().uuidString, "timestamp": Date.now.addingTimeInterval(0.01).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), "sessionId": conversationSession, "cwd": conversationFolder, "message": ["role": "user", "content": argument]])
                }
                let data = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }.reduce(into: Data()) { $0.append($1); $0.append(10) }
                if let handle = try? FileHandle(forWritingTo: conversationTranscript) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }

            case "probe":
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
                let height = NSApp.windows.first?.contentView?.bounds.height ?? 0
                var top: Int?
                for _ in 0..<4 where top == nil && parts.count > 1 {
                    let views = NSApp.windows.lazy.compactMap(\.contentView).flatMap(descendants)
                    top = views.compactMap { $0 as? NSTextView }.first { $0.string.contains(parts[1]) }.map { Int(height - $0.convert($0.bounds, to: nil).maxY) }
                    if top == nil { try? await Task.sleep(for: .milliseconds(250)) }
                }
                print("probe \(parts[0]) statusRowTop \(ConversationProbe.statusRowTop.map { String(Int($0)) } ?? "none")")
                print("probe \(parts[0]) bubbleTop \(top.map(String.init) ?? "none")")

            case "keys":
                let parts = argument.split(separator: ":").map(String.init)
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                guard let textView = NSApp.windows.lazy.compactMap(\.contentView).flatMap(descendants).compactMap({ $0 as? ComposerTextView }).first, let clip = textView.enclosingScrollView?.contentView else { break }

                textView.window?.makeFirstResponder(textView)
                let origins = NSMutableArray()
                let recordOrigin: @MainActor () -> Void = { origins.add(clip.bounds.origin.y) }
                clip.postsBoundsChangedNotifications = true
                let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
                    MainActor.assumeIsolated { recordOrigin() }
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                for line in 0..<(Int(parts[0]) ?? 40) {
                    for character in "line \(line) of typed text\n" {
                        textView.insertText(String(character), replacementRange: textView.selectedRange())
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    save(".\(parts[1])-\(line).png")
                }
                let values = origins.compactMap { $0 as? CGFloat }
                let drops = zip(values, values.dropFirst()).count(where: { $1 < $0 })
                print("origins \(values.map { String(format: "%.0f", $0) }.joined(separator: " "))")
                print("origin decreases \(drops), frame height \(clip.frame.height)")

            case "burst":
                let parts = argument.split(separator: ":").map(String.init)
                for frame in 0..<(Int(parts[0]) ?? 8) {
                    save(".\(parts[2])-\(frame).png")
                    try? await Task.sleep(for: .milliseconds(Int(parts[1]) ?? 40))
                }

            default: break
            }
            try? await Task.sleep(for: .milliseconds(name == "wait" ? Int(argument) ?? 500 : name == "burst" || steps.dropFirst(index + 1).first?.hasPrefix("burst:") == true ? 0 : 700))
            state()
        }
        log()
    }

    static func captureConversation(store: Store, window: NSWindow, output: URL) async {
        let width = UserDefaults.standard.double(forKey: "snapshotConversationWidth")
        let height = UserDefaults.standard.double(forKey: "snapshotConversationHeight")
        window.setContentSize(NSSize(width: width > 0 ? width : 1100, height: height > 0 ? height : 900))
        let save = { (suffix: String) in
            guard let image = image(of: window) else { return }

            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
        }
        let status = UserDefaults.standard.string(forKey: "snapshotConversationStatus") ?? (showsEmptyConversation || showsLongCode || showsWatching || showsSlashCommands || showsShellCompletions ? "idle" : "busy")
        let rawLog = UserDefaults.standard.string(forKey: "snapshotConversationRawLog")
        let title = UserDefaults.standard.string(forKey: "snapshotTerminalTitle") ?? (showsCodexApproval ? "[ ! ] Action Required" : showsCodexTasks ? "Ready" : "")
        let command = rawLog.map { "/bin/zsh -c 'stty raw -echo; printf \"\\033[?2004h\"; exec cat >> \"\($0)\"'" } ?? "/bin/zsh -c 'printf \"\\033]0;\(title)\\007\"; echo the terminal is still running; sleep 600'"
        store.openShell(cwd: conversationFolder, command: command)
        store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: conversationFolder, sessionID: usesCodexConversation ? codexConversationSession : conversationSession, agent: usesCodexConversation ? .codex : .claude, terminal: $0.terminal) : $0 }
        let waitingFor = UserDefaults.standard.string(forKey: "snapshotConversationWaitingFor") ?? "permission prompt"
        if usesCodexConversation {
            seedCodexConversationFixture()
            if showsCodexTasks {
                store.fakeTerminalTasks[codexConversationSession] = [
                    RemoteTask(id: "fixture-shell", kind: RemoteTask.shell, title: "swift test --filter ExportTests", started: .now - 50, command: "swift test --filter ExportTests"),
                ]
            }
            store.refresh()
        } else {
            store.fakeLiveSessions = fakeConversationLive(status: status, waitingFor: status == "waiting" ? waitingFor : nil, updatedSecondsAgo: 20).map { [$0] } ?? []
        }
        store.refreshLive()
        guard let tab = store.tabs.first(where: { $0.id == store.selectedTabID }) else { exit(1) }

        let surface = { (label: String) in
            let view = tab.terminal.attachedPlatformView.map { "\(ObjectIdentifier($0))" } ?? "none"
            print("terminal surface \(label): view \(view), visible \(tab.terminal.isSurfaceVisible), shows conversation \(store.selectedShowsConversation), conversation models \(store.conversationModels.count)")
        }
        try? await Task.sleep(for: .seconds(1))
        surface("before")
        print("switch visibility: toolbar button \(store.canShowConversation), footer \(store.selectedStatusBarIsReachable)")
        if UserDefaults.standard.bool(forKey: "snapshotPerf") {
            await measureConversationPerformance(store: store, tab: tab, window: window, canStream: !usesCodexConversation)
            ProcessAncestry.hangUpDescendants()
            print("conversation performance complete")
            exit(0)
        }
        AppAction.showConversation.perform(on: store)
        let deadline = Date.now + 20
        while Date.now < deadline, store.conversationModels[tab.id].map({ showsEmptyConversation ? !$0.hasLoaded : $0.turns.isEmpty }) ?? true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let slashText = UserDefaults.standard.string(forKey: "snapshotConversationSlashText") ?? "/co"
        if showsSlashCommands { store.conversationModels[tab.id]?.setText(slashText.replacing("|", with: "")) }
        if showsShellCompletions { store.conversationModels[tab.id]?.setText("!git ch") }
        try? await Task.sleep(for: .seconds(2))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let composer = NSApp.windows.lazy.compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? ComposerTextView }.first
        if showsSlashCommands, let composer, let caret = slashText.firstIndex(of: "|") {
            composer.window?.makeFirstResponder(composer)
            composer.setSelectedRange(NSRange(location: slashText.distance(from: slashText.startIndex, to: caret), length: 0))
            composer.refreshCompletions()
            try? await Task.sleep(for: .seconds(1))
        }
        surface("in conversation")
        if showsSlashCommands { save(".slash-open.png") }
        if showsSlashCommands, UserDefaults.standard.bool(forKey: "snapshotConversationSlashAccept"), let composer {
            print("slash accepted \(composer.slashPicker?.accept() ?? false)")
            try? await Task.sleep(for: .seconds(1))
            print("slash text \(composer.string.debugDescription) caret \(composer.selectedRange().location)")
            save(".slash-accepted.png")
        }
        print("switch visibility: toolbar button \(store.canShowConversation), footer \(store.selectedStatusBarIsReachable)")
        if let model = store.conversationModels[tab.id] {
            if showsWatching { print("conversation watch \(model.pullRequestWatch?.title ?? "none")") }
            print("conversation shows \(model.entryCount) entries in \(model.turns.count) turns, \(model.tasks.count) running tasks, queued \(model.queued.count), context \(model.context.map { "\($0.model) \($0.tokens ?? 0) tokens" } ?? "none")")
            for turn in model.turns {
                let parts = turn.parts.map { part -> String in
                    switch part {
                    case let .reply(entry): "reply(\(entry.text.prefix(24)))"
                    case let .work(calls): "work(\(calls.map { "\($0.displayName) \($0.arguments.prefix(24)) -> \($0.resultSummary?.text ?? "open")" }.joined(separator: "; ")))"
                    case let .cards(calls): "cards(\(calls.map { "\($0.cardTitle) \($0.isBackgroundShell ? "shell" : "agent")" }.joined(separator: "; ")))"
                    }
                }
                print("  turn \(turn.prompt?.text.prefix(30) ?? "no prompt") | duration \(turn.duration.map { $0.formatted() } ?? "-") | changes \(turn.fileChanges.map { "\($0.files) files +\($0.added ?? 0) -\($0.removed ?? 0)" } ?? "none") | \(parts.joined(separator: ", "))")
            }
            for task in model.tasks { print("  running \(task.kind) \(task.title) \(task.agentType ?? "")") }
        }
        if UserDefaults.standard.bool(forKey: "snapshotConversationSubagent") {
            if showsCodexTasks {
                store.conversationModels[tab.id]?.openAgent(agentID: codexConversationChild, toolUseID: "fixture-agent")
            } else {
                store.conversationModels[tab.id]?.openAgent(agentID: "agent-docs", toolUseID: "t8")
            }
            try? await Task.sleep(for: .seconds(1))
        }
        save(".conversation.png")
        if UserDefaults.standard.bool(forKey: "snapshotConversationSelect") {
            await testConversationSelection(store: store, tab: tab, window: window, save: save)
        }
        if let script = UserDefaults.standard.string(forKey: "snapshotConversationDrive") {
            await driveConversation(script, store: store, tab: tab, rawLog: rawLog, save: save)
            ProcessAncestry.hangUpDescendants()
            exit(0)
        }
        AppAction.showTerminal.perform(on: store)
        try? await Task.sleep(for: .seconds(1))
        surface("after Show Terminal")
        print("switch visibility: toolbar button \(store.canShowConversation), footer \(store.selectedStatusBarIsReachable)")
        save(".terminal.png")
        AppAction.showConversation.perform(on: store)
        try? await Task.sleep(for: .seconds(1))
        surface("after Show Conversation again")
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }
}
#endif
