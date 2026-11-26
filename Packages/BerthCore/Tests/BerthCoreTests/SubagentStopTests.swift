import BerthCore
import Foundation
import Testing

struct SubagentStopTests {
    private func task(_ id: String, _ kind: SessionBackgroundTask.Kind, at seconds: Double, status: SessionBackgroundTask.Status = .running, foreground: Bool = false) -> SessionBackgroundTask {
        SessionBackgroundTask(id: id, kind: kind, title: id, started: Date(timeIntervalSince1970: seconds), status: status, runsInForeground: foreground)
    }

    @Test func onlyTheVerifiedSeriesIsSupported() {
        #expect(SubagentStop.isSupported(version: "2.1.332"))
        #expect(SubagentStop.isSupported(version: "2.1.0"))
        #expect(!SubagentStop.isSupported(version: "2.2.0"))
        #expect(!SubagentStop.isSupported(version: "3.1.4"))
        #expect(!SubagentStop.isSupported(version: "2"))
        #expect(!SubagentStop.isSupported(version: nil))
    }

    @Test func aLoneAgentIsStoppedFromItsDetailView() {
        let agent = task("a", .agent, at: 10)
        #expect(SubagentStop.keys(stopping: agent, among: [agent]) == [.command("/tasks"), .enter, .stop, .escape])
    }

    @Test func agentsSitBehindShellsAndMonitorsNewestFirst() {
        let tasks = [
            task("late", .agent, at: 30),
            task("early", .agent, at: 20),
            task("watch", .monitor, at: 5),
            task("build", .shell, at: 40),
            task("tab", .terminal, at: 1),
            task("done", .agent, at: 2, status: .completed),
            task("inline", .agent, at: 3, foreground: true),
        ]
        #expect(SubagentStop.keys(stopping: tasks[1], among: tasks) == [.command("/tasks"), .enter, .down, .down, .down, .stop, .escape])
        #expect(SubagentStop.keys(stopping: tasks[0], among: tasks) == [.command("/tasks"), .enter, .down, .down, .stop, .escape])
    }

    @Test func foregroundFinishedAndNonAgentTasksHaveNoKeys() {
        let inline = task("inline", .agent, at: 1, foreground: true)
        let done = task("done", .agent, at: 2, status: .completed)
        let shell = task("build", .shell, at: 3)
        #expect(SubagentStop.keys(stopping: inline, among: [inline]) == nil)
        #expect(SubagentStop.keys(stopping: done, among: [done]) == nil)
        #expect(SubagentStop.keys(stopping: shell, among: [shell]) == nil)
    }
}
