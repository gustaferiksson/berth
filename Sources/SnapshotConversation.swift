#if DEBUG
import AppKit
import BerthCore
import Foundation
import GhosttyTerminal

extension Snapshot {
    static let conversationFolder = "/private/tmp/berth-conversation-fixture"
    static let conversationSession = "conversation-fixture"

    private static var conversationStart: Date { Date.now.addingTimeInterval(-420) }

    static func seedConversationFixture() {
        guard UserDefaults.standard.bool(forKey: "snapshotConversation") else { return }
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else {
            FileHandle.standardError.write(Data("snapshot: -snapshotConversation needs CFFIXED_USER_HOME pointing at an empty fixture home\n".utf8))
            exit(1)
        }

        try? FileManager.default.createDirectory(atPath: conversationFolder, withIntermediateDirectories: true)
        let slug = conversationFolder.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        let directory = Store.claudeDirectory.appending(path: "projects/\(slug)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = conversationRecords().map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appending(path: "\(conversationSession).jsonl"), atomically: true, encoding: .utf8)
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
        let file = "\(conversationFolder)/Sources/Export.swift"
        return [
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
            prompt("Nice. Now add a plan name column, start the slow migration check in the background and have an agent review the docs.", 90),
            assistant(5, [text("I'll add the column, then run both checks in parallel.")]),
            assistant(4, [use("t5", "Read", ["file_path": file])]),
            result("t5", (1...60).map { "\($0)\tline \($0)" }.joined(separator: "\n"), 1, [:]),
            assistant(15, [use("t6", "Edit", ["file_path": file, "old_string": "struct Row {\n    let date: Date\n    let amount: Decimal\n}", "new_string": "struct Row {\n    let date: Date\n    let amount: Decimal\n    let planName: String\n}"])]),
            result("t6", "The file \(file) has been updated.", 1, [:]),
            assistant(6, [text("Column added. Starting the migration check and the docs review now."), use("t7", "Bash", ["command": "swift test --filter MigrationTests --parallel", "description": "Run the migration check in the background", "run_in_background": true])]),
            result("t7", "Command running in background with ID: bg-migration. Output is being written to: /private/tmp/bg-migration.output", 1, ["toolUseResult": ["backgroundTaskId": "bg-migration"]]),
            assistant(3, [use("t8", "Agent", ["description": "Review the docs for the export column", "subagent_type": "general-purpose", "prompt": "Read docs/columns.md and list what must change for the plan name column.", "run_in_background": true])]),
            result("t8", "Async agent launched successfully.\nagentId: agent-docs (internal ID, do not mention to user)", 1, ["toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": "agent-docs", "description": "Review the docs for the export column"]]),
            assistant(30, [use("t9", "Read", ["file_path": "\(conversationFolder)/docs/columns.md"])]),
        ]
    }

    static func captureConversation(store: Store, window: NSWindow, output: URL) async {
        window.setContentSize(NSSize(width: 1100, height: UserDefaults.standard.double(forKey: "snapshotConversationHeight") > 0 ? UserDefaults.standard.double(forKey: "snapshotConversationHeight") : 900))
        let save = { (suffix: String) in
            guard let image = image(of: window) else { return }

            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output.path + suffix))
        }
        let status = UserDefaults.standard.string(forKey: "snapshotConversationStatus") ?? "busy"
        let waitingFor = status == "waiting" ? #","waitingFor":"permission prompt""# : ""
        let started = Int(conversationStart.timeIntervalSince1970 * 1000) - 60_000
        store.openShell(cwd: conversationFolder, command: "/bin/zsh -c 'echo the terminal is still running; sleep 600'")
        store.tabs = store.tabs.map { $0.id == store.selectedTabID ? Tab(id: $0.id, kind: .claude, cwd: conversationFolder, sessionID: conversationSession, terminal: $0.terminal) : $0 }
        if let live = try? JSONDecoder().decode(LiveSession.self, from: Data(#"{"pid":\#(getpid()),"sessionId":"\#(conversationSession)","cwd":"\#(conversationFolder)","status":"\#(status)"\#(waitingFor),"startedAt":\#(started)}"#.utf8)) {
            store.fakeLiveSessions = [live]
            store.refreshLive()
        }
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
        save(".conversation.png")
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
