#if DEBUG
import AppKit
import BerthCore
import Foundation
import GhosttyTerminal

extension Snapshot {
    static func prepareBackgroundTasks(store: Store) -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "berth-background-tasks-\(UUID())")
        let session = "snapshot-background-tasks"
        let transcript = folder.appending(path: "\(session).jsonl")
        let subagents = folder.appending(path: "\(session)/subagents")
        let shellOutput = folder.appending(path: "shell-live.output")
        let finishedOutput = folder.appending(path: "shell-done.output")
        let now = Date.now
        let stamp = { (offset: Double) in (now + offset).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
        let rows = [
            #"{"type":"user","timestamp":"\#(stamp(-900))","message":{"content":[{"type":"tool_result","tool_use_id":"repl_1","content":""}]},"toolUseResult":{"backgroundTaskId":"shell-stopped"}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-700))","message":{"content":[{"type":"tool_result","tool_use_id":"repl_2","content":""}]},"toolUseResult":{"message":"Successfully stopped task: shell-stopped (npm run dev)","task_id":"shell-stopped","task_type":"local_bash","command":"npm run dev"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-520))","message":{"content":[{"type":"tool_use","id":"tool-test","name":"Bash","input":{"command":"swift test --filter ExportTests","description":"Run export tests","run_in_background":true}}]}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-519))","message":{"content":[{"type":"tool_result","tool_use_id":"tool-test","content":"Command running in background with ID: shell-done. Output is being written to: \#(finishedOutput.path)"}]},"toolUseResult":{"backgroundTaskId":"shell-done"}}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"\#(stamp(-504))","content":"<task-notification><task-id>shell-done</task-id><status>completed</status><summary>Export tests completed with exit code 0</summary></task-notification>"}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-200))","message":{"content":[{"type":"tool_use","id":"tool-agent","name":"Agent","input":{"description":"Review export retry behavior","prompt":"Check how the export worker retries an interrupted upload.","run_in_background":true}}]}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-199))","message":{"content":[{"type":"tool_result","tool_use_id":"tool-agent","content":"Async agent launched successfully."}]},"toolUseResult":{"isAsync":true,"agentId":"retry-review"}}"#,
            #"{"type":"assistant","timestamp":"\#(stamp(-73))","message":{"content":[{"type":"tool_use","id":"tool-build","name":"Bash","input":{"command":"swift build --target ExportWorker","description":"Build the export worker","run_in_background":true}}]}}"#,
            #"{"type":"user","timestamp":"\#(stamp(-72))","message":{"content":[{"type":"tool_result","tool_use_id":"tool-build","content":"Command running in background with ID: shell-live. Output is being written to: \#(shellOutput.path)"}]},"toolUseResult":{"backgroundTaskId":"shell-live"}}"#,
        ]
        let agentRows = [
            #"{"type":"user","uuid":"agent-prompt","timestamp":"\#(stamp(-200))","sessionId":"\#(session)","isSidechain":true,"message":{"role":"user","content":"Check how the export worker retries an interrupted upload."}}"#,
            #"{"type":"assistant","uuid":"agent-reply","timestamp":"\#(stamp(-58))","sessionId":"\#(session)","isSidechain":true,"message":{"id":"agent-message","role":"assistant","model":"claude-fixture","content":[{"type":"text","text":"The worker restores its checkpoint before retrying. A retry resumes at the first unacknowledged chunk and reuses the upload identifier."}]}}"#,
            #"{"type":"assistant","uuid":"agent-followup","timestamp":"\#(stamp(-38))","sessionId":"\#(session)","isSidechain":true,"message":{"id":"agent-message-2","role":"assistant","model":"claude-fixture","content":[{"type":"text","text":"I’m checking whether the same rule holds when the final acknowledgement gets lost."}]}}"#,
        ]
        do {
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            try (rows.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            try (agentRows.joined(separator: "\n") + "\n").write(to: subagents.appending(path: "agent-retry-review.jsonl"), atomically: true, encoding: .utf8)
            try """
            $ swift build --target ExportWorker
            Building for debugging...
            [1/9] Write sources
            [2/9] Write swift-version.txt
            [3/9] Emitting module ExportCore
            [4/9] Compiling ExportCore Checkpoint.swift
            [5/9] Compiling ExportCore RetryPolicy.swift
            [6/9] Compiling ExportWorker Upload.swift

            """.write(to: shellOutput, atomically: true, encoding: .utf8)
            try """
            $ swift test --filter ExportTests
            ✓ exportsAllRows
            ✓ resumesFromCheckpoint
            ✓ rejectsExpiredUpload
            Test run passed. 3 tests in 0.28 s.
            """.write(to: finishedOutput, atomically: true, encoding: .utf8)
        } catch {
            fail("could not seed background tasks. \(error)")
        }

        let parent = UUID()
        let terminal = UUID()
        let cwd = "/private/tmp"
        store.openShell(cwd: cwd, command: "/bin/sh -c 'printf \"\\033]0;Export worker\\007Review retries for the export worker.\\n\\nBuild and tests are running.\\n\"; exec /bin/sleep 120'", id: parent)
        store.tabs = store.tabs.map { $0.id == parent ? Tab(id: parent, kind: .claude, cwd: cwd, sessionID: session, terminal: $0.terminal) : $0 }
        store.openShell(cwd: cwd, command: "/bin/sh -c 'printf \"\\033]0;Export preview\\007\"; exec /bin/sleep 120'", id: terminal, parent: parent, taskTitle: "Run local export preview")
        store.activate(.tab(parent))
        store.backgroundTaskFixture = BackgroundTaskSource(tabID: parent, sessionID: session, root: folder, transcript: transcript, agent: .claude)
        store.fakeLiveSessions = [LiveSession(pid: 0, sessionId: session, cwd: cwd, status: UserDefaults.standard.string(forKey: "snapshotBackgroundTaskStatus") ?? "idle", startedAt: (now - 600).timeIntervalSince1970 * 1000, version: UserDefaults.standard.string(forKey: "snapshotBackgroundTaskVersion") ?? "2.1.332")]
        store.refreshLive()
        let id = switch UserDefaults.standard.string(forKey: "snapshotBackgroundTask") {
        case "agent": "retry-review"
        case "finished": "shell-done"
        case "stopped": "shell-stopped"
        case "terminal": terminal.uuidString
        default: "shell-live"
        }
        store.showTasksPane(selecting: id)
        return folder
    }

    static func captureBackgroundTasks(in folder: URL, store: Store, window: NSWindow, output: URL) async {
        defer { try? FileManager.default.removeItem(at: folder) }

        let deadline = Date.now + 8
        while store.backgroundTaskModel.tasks.count < 3, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let groups = BackgroundTaskGroups(store.backgroundTasks)
        guard groups.running.count == 3, groups.finished.map(\.status) == [.exit(0), .stopped], groups.finished.last?.title == "npm run dev" else {
            fail("background tasks did not load, running \(groups.running.map(\.id)), finished \(groups.finished.map(\.id))")
        }
        guard let selected = store.selectedBackgroundTask(in: store.backgroundTasks) else { fail("background task selection missing") }

        let id = selected.id
        try? await Task.sleep(for: .seconds(1))
        if id == "shell-live" {
            do {
                let handle = try FileHandle(forWritingTo: folder.appending(path: "shell-live.output"))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("[7/9] Compiling ExportWorker Runner.swift\n".utf8))
                try handle.close()
            } catch {
                fail("could not append background shell output. \(error)")
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if selected.kind == .terminal {
            guard let tab = store.tabs.first(where: { $0.id.uuidString == id }),
                  let surface = tab.terminal.attachedPlatformView, let sessionSurface = store.sessionTab?.terminal.attachedPlatformView
            else { fail("could not find the mounted terminal surfaces") }

            let width = sessionSurface.frame.width
            store.activate(.tab(tab.id))
            try? await Task.sleep(for: .milliseconds(500))
            guard store.shownPane == .terminal, tab.terminal.attachedPlatformView === surface,
                  abs(sessionSurface.frame.width - width) < 1 else { fail("opening an owned terminal changed its surface or the session width") }

            store.showTasksPane(selecting: id)
            try? await Task.sleep(for: .milliseconds(500))
            guard tab.terminal.attachedPlatformView === surface, abs(sessionSurface.frame.width - width) < 1 else {
                fail("returning to Tasks changed the terminal surface or the session width")
            }

            print("background task terminal kept its surface and session width \(width)")
        }
        print("background tasks running \(groups.running.map(\.id)), finished \(groups.finished.map(\.id)), selected \(id)")
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }),
              let image = image(of: window),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: output)) != nil
        else { fail("could not capture background tasks offscreen") }
    }
}
#endif
