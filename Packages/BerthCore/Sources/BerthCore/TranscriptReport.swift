import Foundation

private let resumeGrace: TimeInterval = 5

public extension TranscriptActivity {
    static func report(_ url: URL, previous: Self, logs previousLogs: [String: AgentLog], live: LiveSession?, catalogDirectory: URL) -> (activity: Self, logs: [String: AgentLog], report: RemoteActivity) {
        var activity = previous
        activity.read(url)
        var logs = previousLogs.filter { activity.runningAgentIDs.contains($0.key) }
        for agent in activity.runningAgentIDs { logs[agent, default: AgentLog()].read(url.deletingPathExtension().appending(path: "subagents/agent-\(agent).jsonl")) }
        let subagents = url.deletingPathExtension().appending(path: "subagents")
        let finished = Set(activity.runningAgentIDs.filter { Self.subagentOutcome(agent: $0, in: subagents) != nil })
        let catalogs = ((try? FileManager.default.contentsOfDirectory(at: catalogDirectory, includingPropertiesForKeys: nil)) ?? []).compactMap { try? Data(contentsOf: $0) }
        let window = activity.model.flatMap { catalogModel($0, catalogs: catalogs).window }
        return (activity, logs, RemoteActivity(tasks: activity.tasks(of: live, now: .now, progress: logs) { finished.contains($0) }, context: activity.context(window: window)))
    }

    internal static func subagentOutcome(agent: String, in subagents: URL) -> SessionBackgroundTask.Status? {
        guard agent.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { return nil }

        let metaURL = subagents.appending(path: "agent-\(agent).meta.json")
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: Any]
        let stopped = meta?["stoppedByUser"] as? Bool == true
        guard meta?["finished"] as? Bool == true || stopped else { return nil }

        let logURL = subagents.appending(path: "agent-\(agent).jsonl")
        let metaDate = (try? metaURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let logDate = (try? logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let metaDate, let logDate, logDate > metaDate.addingTimeInterval(resumeGrace) { return nil }

        return stopped ? .stopped : .completed
    }
}
