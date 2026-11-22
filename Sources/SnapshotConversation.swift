#if DEBUG
import AppKit
import BerthCore
import Foundation
import GhosttyTerminal

extension Snapshot {
    static let conversationFolder = "/private/tmp/berth-conversation-fixture"
    static let conversationSession = "conversation-fixture"

    private static let codexConversationSession = "5b34c260-0c36-4721-bcfa-d56c78a9ce31"
    private static var usesCodexConversation: Bool { UserDefaults.standard.string(forKey: "snapshotConversationAgent") == "codex" }

    private static var conversationStart: Date { Date.now.addingTimeInterval(-420) }

    static func seedConversationFixture() {
        guard UserDefaults.standard.bool(forKey: "snapshotConversation") else { return }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else {
            FileHandle.standardError.write(Data("snapshot: -snapshotConversation needs CFFIXED_USER_HOME pointing at an empty fixture home\n".utf8))
            exit(1)
        }

        try? FileManager.default.createDirectory(atPath: conversationFolder, withIntermediateDirectories: true)
        if usesCodexConversation {
            guard UserDefaults.standard.bool(forKey: "codexEnabled") else {
                FileHandle.standardError.write(Data("snapshot: -snapshotConversationAgent codex requires -codexEnabled YES\n".utf8))
                exit(1)
            }

            seedCodexConversationFixture()
            return
        }
        let slug = conversationFolder.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let directory = Store.claudeDirectory.appending(path: "projects/\(slug)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effort = UserDefaults.standard.string(forKey: "snapshotConversationEffort").map { [#"{"type":"api-request","querySource":"repl_main_thread","params":{"model":"claude-sonnet-4-5","output_config":{"effort":"\#($0)"}}}"#] } ?? []
        let lines = effort + conversationRecords().map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appending(path: "\(conversationSession).jsonl"), atomically: true, encoding: .utf8)
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

    private static func seedCodexConversationFixture() {
        let directory = Store.codexDirectory.appending(path: "sessions/2026/01/02")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let payloads: [(String, String)] = [
            ("session_meta", #"{"id":"\#(codexConversationSession)","cwd":"\#(conversationFolder)","timestamp":"\#(timestamp)","originator":"codex-tui","thread_source":"user"}"#),
            ("turn_context", #"{"cwd":"\#(conversationFolder)","model":"gpt-test"}"#),
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
        let completion = (UserDefaults.standard.string(forKey: "snapshotConversationStatus") ?? "busy") == "busy" ? [] : [("event_msg", #"{"type":"task_complete"}"#)]
        let now = Date.now
        let lines = (payloads + completion).enumerated().map { index, record in
            let date = now.addingTimeInterval(Double(min(index - payloads.count + 2, 0))).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
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
            assistant(40, [text("Fixed. The export grouped rows by the machine's time zone, so I pinned it.\n\n## What changed\n\n- `Export.swift` now sets `formatter.timeZone` to **Europe/Stockholm**\n- Both export tests pass\n- Nothing else reads the formatter\n\n```swift\nformatter.timeZone = TimeZone(identifier: \"Europe/Stockholm\")\n```\n\n| Machine | Zone | Result |\n| --- | --- | --- |\n| Mac | Stockholm | passes |\n| CI | UTC | passes now |")]),
            base("user", 90, ["role": "user", "content": [["type": "text", "text": "Nice. Now add a plan name column, start the slow migration check in the background and have an agent review the docs."], ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": fixtureImage().base64EncodedString()]]]]),
            assistant(5, [text("I'll add the column, then run both checks in parallel.")]),
            assistant(4, [use("t5", "Read", ["file_path": file])]),
            result("t5", (1...60).map { "\($0)\tline \($0)" }.joined(separator: "\n"), 1, [:]),
            assistant(15, [use("t6", "Edit", ["file_path": file, "old_string": "struct Row {\n    let date: Date\n    let amount: Decimal\n}", "new_string": "struct Row {\n    let date: Date\n    let amount: Decimal\n    let planName: String\n}"])]),
            result("t6", "The file \(file) has been updated.", 1, [:]),
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
            assistant(3, [text("The migration check is still running, the docs agent has started.")]),
            assistant(3, [use("t12", "SendMessage", ["to": "agent-docs", "message": "Also check the CSV header."])]),
            result("t12", "", 1, [:]),
            assistant(30, [use("t9", "Read", ["file_path": "\(conversationFolder)/docs/columns.md"])]),
        ] + pendingRecords(assistant: assistant, use: use, result: result)
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

    private static func fixtureImage() -> Data {
        let image = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemIndigo])?.draw(in: rect, angle: 35)
            return true
        }
        return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
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
        for step in script.split(separator: "|").map(String.init) {
            let (name, argument) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
            print("step \(step)")
            switch name {
            case "type": store.conversationModels[tab.id]?.draft.text = argument

            case "attach": store.conversationModels[tab.id]?.append([URL(fileURLWithPath: argument)])

            case "remove": store.conversationModels[tab.id]?.remove(URL(fileURLWithPath: argument))

            case "send": await store.conversationModels[tab.id]?.send()

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

            case "drop": store.fakeLiveSessions = []

            case "snap": save(".\(argument).png")

            case "preview": if let data = store.conversationModels[tab.id]?.turns.lazy.compactMap({ $0.prompt?.images?.first }).first { ConversationImagePreview.shared.show(data) }

            case "log": log()

            default: break
            }
            try? await Task.sleep(for: .milliseconds(name == "wait" ? Int(argument) ?? 500 : 700))
            state()
        }
        log()
    }

    static func captureConversation(store: Store, window: NSWindow, output: URL) async {
        window.setContentSize(NSSize(width: 1100, height: UserDefaults.standard.double(forKey: "snapshotConversationHeight") > 0 ? UserDefaults.standard.double(forKey: "snapshotConversationHeight") : 900))
        let save = { (suffix: String) in
            guard let image = image(of: window) else { return }

            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
        }
        let status = UserDefaults.standard.string(forKey: "snapshotConversationStatus") ?? "busy"
        let rawLog = UserDefaults.standard.string(forKey: "snapshotConversationRawLog")
        let command = rawLog.map { "/bin/zsh -c 'stty raw -echo; printf \"\\033[?2004h\"; exec cat >> \"\($0)\"'" } ?? "/bin/zsh -c 'printf \"\\033]0;\(UserDefaults.standard.string(forKey: "snapshotTerminalTitle") ?? "")\\007\"; echo the terminal is still running; sleep 600'"
        store.openShell(cwd: conversationFolder, command: command)
        store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: conversationFolder, sessionID: usesCodexConversation ? codexConversationSession : conversationSession, agent: usesCodexConversation ? .codex : .claude, terminal: $0.terminal) : $0 }
        let waitingFor = UserDefaults.standard.string(forKey: "snapshotConversationWaitingFor") ?? "permission prompt"
        if usesCodexConversation {
            seedCodexConversationFixture()
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
        AppAction.showConversation.perform(on: store)
        let deadline = Date.now + 20
        while Date.now < deadline, store.conversationModels[tab.id]?.turns.isEmpty ?? true { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(2))
        surface("in conversation")
        if UserDefaults.standard.bool(forKey: "snapshotPerf") {
            await measurePerformance(window: window, store: store)
            ProcessAncestry.hangUpDescendants()
            print("conversation performance complete")
            exit(0)
        }
        if let model = store.conversationModels[tab.id] {
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
            store.conversationModels[tab.id]?.openAgent(agentID: "agent-docs", toolUseID: "t8")
            try? await Task.sleep(for: .seconds(1))
        }
        save(".conversation.png")
        if let script = UserDefaults.standard.string(forKey: "snapshotConversationDrive") {
            await driveConversation(script, store: store, tab: tab, rawLog: rawLog, save: save)
            ProcessAncestry.hangUpDescendants()
            exit(0)
        }
        AppAction.showTerminal.perform(on: store)
        try? await Task.sleep(for: .seconds(1))
        surface("after Show Terminal")
        save(".terminal.png")
        AppAction.showConversation.perform(on: store)
        try? await Task.sleep(for: .seconds(1))
        surface("after Show Conversation again")
        ProcessAncestry.hangUpDescendants()
        exit(0)
    }
}
#endif
