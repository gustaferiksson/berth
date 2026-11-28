import BerthCore
import Foundation
import Testing

struct BackgroundTasksTests {
    @Test func transcriptHistoryKeepsOutputAndMovesTasksBetweenGroups() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "background-tasks-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "session.jsonl")
        let output = folder.appending(path: "build.output")
        let now = try Date("2026-11-01T10:03:00Z", strategy: .iso8601)
        let live = LiveSession(pid: 1, sessionId: "session", cwd: folder.path, status: "idle", startedAt: (now - 240).timeIntervalSince1970 * 1000)

        let launches = [
            #"{"type":"assistant","timestamp":"2026-11-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"tool-fg","name":"Bash","input":{"command":"pwd"}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-fg","content":"/example"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T10:00:02.000Z","message":{"content":[{"type":"tool_use","id":"tool-build","name":"Bash","input":{"command":"make build","description":"Build the worker","run_in_background":true}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:00:03.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-build","content":"Command running in background with ID: build. Output is being written to: \#(output.path)."}]},"toolUseResult":{"backgroundTaskId":"build"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T10:01:00.000Z","message":{"content":[{"type":"tool_use","id":"tool-agent","name":"Task","input":{"description":"Check exports","prompt":"Read the export tests."}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:01:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-agent","content":"Async agent launched successfully."}]},"toolUseResult":{"isAsync":true,"agentId":"review"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T10:02:40.000Z","message":{"content":[{"type":"tool_use","id":"tool-sync","name":"Agent","input":{"prompt":"Check retries.","description":"Review retries"}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:02:45.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-sync","content":[{"type":"text","text":"Retries reuse the upload identifier."}]}]},"toolUseResult":{"agentId":"inline-review"}}"#,
        ]
        let initial = launches.joined(separator: "\n") + "\n"
        try initial.write(to: transcript, atomically: true, encoding: .utf8)
        try "Compiling worker\n".write(to: output, atomically: true, encoding: .utf8)
        var activity = TranscriptActivity(keepsTaskHistory: true)
        activity.read(transcript)
        let running = BackgroundTaskGroups(activity.backgroundTasks(of: live, in: transcript))
        #expect(running.running.map(\.id) == ["review", "build"])
        #expect(running.running.map(\.toolUseID) == ["tool-agent", "tool-build"])
        let shell = try #require(running.running.last)
        #expect(shell.elapsed(at: now) == .seconds(178))
        #expect(shell.elapsed(at: now - 500) == .zero)
        #expect(shell.outputFile.flatMap { TaskOutput.tail($0) } == "Compiling worker")
        #expect(running.finished.map(\.agentID) == ["inline-review"])
        #expect(running.finished.map(\.result) == ["Retries reuse the upload identifier."])

        let updates = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:03:00.000Z","content":"<task-notification><task-id>build</task-id><status>failed</status><summary>Build failed with exit code 2</summary></task-notification>"}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T10:03:10.000Z","message":{"content":[{"type":"tool_use","id":"tool-stop","name":"TaskStop","input":{"task_id":"review"}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:03:11.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-stop","content":"Stopped"}]},"toolUseResult":{"task_id":"review"}}"#,
        ].joined(separator: "\n") + "\n"
        try (initial + updates).write(to: transcript, atomically: true, encoding: .utf8)
        try "Compiling worker\nCompilation failed\n".write(to: output, atomically: true, encoding: .utf8)
        activity.read(transcript)
        let finished = BackgroundTaskGroups(activity.backgroundTasks(of: live, in: transcript))
        #expect(finished.running.isEmpty)
        #expect(finished.finished.map(\.status) == [.completed, .stopped, .exit(2)])
        #expect(finished.finished.last?.outputFile.flatMap { TaskOutput.tail($0) } == "Compiling worker\nCompilation failed")
    }

    @Test func virtualShellKeepsAnEarlierCompletionAndUsesOnlyItsOwnOutputFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "virtual-task-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "session.jsonl")
        let output = folder.appending(path: "virtual.output")
        let records = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-01T10:00:01.000Z","content":"<task-notification><task-id>virtual</task-id><status>completed</status><exit-code>0</exit-code><output-file>\#(output.path)</output-file></task-notification>"}"#,
            #"{"type":"user","timestamp":"2026-11-01T10:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"repl_1","content":""}]},"toolUseResult":{"backgroundTaskId":"virtual","description":"Watch preview","outputFile":"\#(folder.path)/other.output"}}"#,
        ].joined(separator: "\n") + "\n"
        try records.write(to: transcript, atomically: true, encoding: .utf8)
        var activity = TranscriptActivity(keepsTaskHistory: true)
        activity.read(transcript)
        let groups = BackgroundTaskGroups(activity.backgroundTasks(of: nil, in: transcript))
        #expect(groups.running.isEmpty)
        let task = try #require(groups.finished.first)
        #expect(task.status == .exit(0))
        #expect(task.outputFile == output)
    }

    @Test func runningShellWithoutAnOutputPathFindsItsFileUnderTheSessionTasksFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "repl-shell-\(UUID())")
        let tasks = folder.appending(path: "tmp-root/-example-worktree/session/tasks")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "session.jsonl")
        let output = tasks.appending(path: "watch.output")
        try "".write(to: output, atomically: true, encoding: .utf8)
        let records = #"{"type":"user","timestamp":"2026-11-01T10:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"repl_1","content":""}]},"toolUseResult":{"backgroundTaskId":"watch"}}"# + "\n"
        try records.write(to: transcript, atomically: true, encoding: .utf8)
        let live = LiveSession(pid: 1, sessionId: "session", cwd: folder.path, status: "idle", startedAt: Date(timeIntervalSince1970: 1_780_000_000).timeIntervalSince1970 * 1000 - 1000)
        var activity = TranscriptActivity(keepsTaskHistory: true)
        activity.read(transcript)
        let task = try #require(activity.backgroundTasks(of: live, in: transcript, tasksRoot: folder.appending(path: "tmp-root")).first)
        #expect(task.title == "Background shell")
        #expect(task.outputFile?.resolvingSymlinksInPath() == output.resolvingSymlinksInPath())
    }

    @Test func taskTailKeepsCompleteLinesAndBoundsLongLines() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "task-tail-\(UUID()).output")
        defer { try? FileManager.default.removeItem(at: url) }
        try "A long prefix\nfirst\n\u{1B}[32msecond\u{1B}[0m\nthird\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(TaskOutput.tail(url, maxBytes: 27, maxLines: 2) == "second\nthird")
        #expect(TaskOutput.tail(url, maxBytes: 6) == "third")
        #expect(TaskOutput.tail(url, maxBytes: 7) == "third")
        try "ABCDEFGHIJK".write(to: url, atomically: true, encoding: .utf8)
        #expect(TaskOutput.tail(url, maxBytes: 4) == "HIJK")
        #expect(TaskOutput.tail(url, maxBytes: 0) == nil)
    }

    @Test func agentCallsStillPendingAreMarkedForegroundUnlessBackgroundRequested() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "background-foreground-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "session.jsonl")
        let rows = [
            #"{"type":"assistant","timestamp":"2026-11-01T10:01:00.000Z","message":{"content":[{"type":"tool_use","id":"tool-inline","name":"Agent","input":{"description":"Review retries","prompt":"Check retries."}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-01T10:01:05.000Z","message":{"content":[{"type":"tool_use","id":"tool-later","name":"Agent","input":{"description":"Check exports","prompt":"Read the export tests.","run_in_background":true}}]}}"#,
        ]
        try (rows.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let started = try Date("2026-11-01T10:00:00Z", strategy: .iso8601)
        let live = LiveSession(pid: 1, sessionId: "session", cwd: folder.path, status: "busy", startedAt: started.timeIntervalSince1970 * 1000)
        var activity = TranscriptActivity(keepsTaskHistory: true)
        activity.read(transcript)
        let tasks = activity.backgroundTasks(of: live, in: transcript).sorted { $0.started < $1.started }
        #expect(tasks.map(\.toolUseID) == ["tool-inline", "tool-later"])
        #expect(tasks.map(\.runsInForeground) == [true, false])
    }

    @Test func backgroundShellWithoutAProcessHoldingItsOutputIsFinished() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "killed-shell-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "session.jsonl")
        let output = folder.appending(path: "dev.output")
        let live = LiveSession(pid: 1, sessionId: "session", cwd: folder.path, status: "idle", startedAt: Date(timeIntervalSince1970: 1_793_000_000).timeIntervalSince1970 * 1000)
        let records = [
            #"{"type":"assistant","timestamp":"2026-11-26T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"tool-dev","name":"Bash","input":{"command":"npm start","description":"Start the acme dev server","run_in_background":true}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-26T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-dev","content":"Command running in background with ID: dev. Output is being written to: \#(output.path)"}]},"toolUseResult":{"backgroundTaskId":"dev"}}"#,
        ].joined(separator: "\n") + "\n"
        try records.write(to: transcript, atomically: true, encoding: .utf8)
        try "ready on http://localhost:5173\n[killed]\n".write(to: output, atomically: true, encoding: .utf8)
        var activity = TranscriptActivity(keepsTaskHistory: true)
        activity.read(transcript)

        let alive = BackgroundTaskGroups(activity.backgroundTasks(of: live, in: transcript, isProcessGone: { _ in false }))
        #expect(alive.running.map(\.id) == ["dev"])

        let gone = BackgroundTaskGroups(activity.backgroundTasks(of: live, in: transcript, isProcessGone: { $0 == output }))
        #expect(gone.running.isEmpty)
        #expect(gone.finished.map(\.title) == ["Start the acme dev server"])
    }

    @Test func virtualTaskStopFinishesAShellAndNamesItAfterItsCommand() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "virtual-stop-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "session.jsonl")
        let live = LiveSession(pid: 1, sessionId: "session", cwd: folder.path, status: "idle", startedAt: Date(timeIntervalSince1970: 1_793_000_000).timeIntervalSince1970 * 1000)
        let records = [
            #"{"type":"user","timestamp":"2026-11-26T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"repl_1","content":""}]},"toolUseResult":{"backgroundTaskId":"dev"}}"#,
            #"{"type":"user","timestamp":"2026-11-26T11:00:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"repl_2","content":""}]},"toolUseResult":{"message":"Successfully stopped task: dev (npm start)","task_id":"dev","task_type":"local_bash","command":"npm start"}}"#,
        ].joined(separator: "\n") + "\n"
        try records.write(to: transcript, atomically: true, encoding: .utf8)
        var activity = TranscriptActivity(keepsTaskHistory: true)
        activity.read(transcript)

        let groups = BackgroundTaskGroups(activity.backgroundTasks(of: live, in: transcript))
        #expect(groups.running.isEmpty)
        #expect(groups.finished.map(\.status) == [.stopped])
        #expect(groups.finished.map(\.title) == ["npm start"])
    }

    @Test func dispatchedScriptsAndTheShellsTheyLeaveBehindRunUntilTheirEnd() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "repl-eval-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let transcript = folder.appending(path: "session.jsonl")
        let output = folder.appending(path: "bdev.output")
        let now = try Date("2026-11-26T10:30:00Z", strategy: .iso8601)
        let live = LiveSession(pid: 1, sessionId: "session", cwd: folder.path, status: "idle", startedAt: (now - 3600).timeIntervalSince1970 * 1000)
        let dispatch = [
            #"{"type":"assistant","timestamp":"2026-11-26T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"tool-repl","name":"REPL","input":{"code":"await $`npm start`","description":"Start the acme dev server"}}]}}"#,
            #"{"type":"user","timestamp":"2026-11-26T10:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool-repl","content":"(dispatched #50)"}]}}"#,
        ]
        let evalDone = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-26T10:10:00.000Z","content":"<event kind=\"repl-eval\" eval=\"50\">npm start was moved to the background. It went on as task bdev, writing to \#(output.path).</event>"}"#
        let notified = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-26T10:20:00.000Z","content":"<task-notification><task-id>bdev</task-id><status>killed</status></task-notification>"}"#
        func tasks(_ records: [String], gone: Bool = false) throws -> [RemoteTask] {
            try (records.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            var activity = TranscriptActivity()
            activity.read(transcript)
            return activity.tasks(of: live, now: now, isProcessGone: { _ in gone }, isFinished: { _ in false })
        }

        let running = try tasks(dispatch)
        #expect(running.map(\.id) == ["eval-50"])
        #expect(running.map(\.title) == ["Start the acme dev server"])
        #expect(try tasks(dispatch + [evalDone]).map(\.id) == ["bdev"])
        #expect(try tasks(dispatch + [evalDone], gone: true).isEmpty)
        #expect(try tasks(dispatch + [evalDone, notified]).isEmpty)
    }
}
