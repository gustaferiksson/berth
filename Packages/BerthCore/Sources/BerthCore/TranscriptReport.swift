import Foundation

public extension TranscriptActivity {
    static func report(_ url: URL, previous: Self, logs previousLogs: [String: AgentLog], live: LiveSession?, catalogDirectory: URL) -> (activity: Self, logs: [String: AgentLog], report: RemoteActivity) {
        var activity = previous
        activity.read(url)
        var logs = previousLogs.filter { activity.runningAgentIDs.contains($0.key) }
        for agent in activity.runningAgentIDs { logs[agent, default: AgentLog()].read(url.deletingPathExtension().appending(path: "subagents/agent-\(agent).jsonl")) }
        let finished = Set(activity.runningAgentIDs.filter { agent in
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url.deletingPathExtension().appending(path: "subagents/agent-\(agent).meta.json")))) as? [String: Any]
            return meta?["finished"] as? Bool == true || meta?["stoppedByUser"] as? Bool == true
        })
        let catalogs = ((try? FileManager.default.contentsOfDirectory(at: catalogDirectory, includingPropertiesForKeys: nil)) ?? []).compactMap { try? Data(contentsOf: $0) }
        let window = activity.model.flatMap { catalogModel($0, catalogs: catalogs).window }
        return (activity, logs, RemoteActivity(tasks: activity.tasks(of: live, now: .now, progress: logs) { finished.contains($0) }, context: activity.context(window: window)))
    }
}
