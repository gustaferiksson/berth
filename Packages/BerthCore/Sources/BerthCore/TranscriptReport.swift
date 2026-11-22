import Foundation

private let resumeGrace: TimeInterval = 5

public extension TranscriptActivity {
    static func report(_ url: URL, previous: Self, logs previousLogs: [String: AgentLog], live: LiveSession?, catalogDirectory: URL) -> (activity: Self, logs: [String: AgentLog], report: RemoteActivity) {
        var activity = previous
        activity.read(url)
        var logs = previousLogs.filter { activity.runningAgentIDs.contains($0.key) }
        for agent in activity.runningAgentIDs { logs[agent, default: AgentLog()].read(url.deletingPathExtension().appending(path: "subagents/agent-\(agent).jsonl")) }
        let subagents = url.deletingPathExtension().appending(path: "subagents")
        let finished = Set(activity.runningAgentIDs.filter { Self.isFinished(agent: $0, in: subagents) })
        let catalogs = ((try? FileManager.default.contentsOfDirectory(at: catalogDirectory, includingPropertiesForKeys: nil)) ?? []).compactMap { try? Data(contentsOf: $0) }
        let window = activity.model.flatMap { catalogModel($0, catalogs: catalogs).window }
        return (activity, logs, RemoteActivity(tasks: activity.tasks(of: live, now: .now, progress: logs) { finished.contains($0) }, context: activity.context(window: window)))
    }

    private static func isFinished(agent: String, in subagents: URL) -> Bool {
        let metaURL = subagents.appending(path: "agent-\(agent).meta.json")
        let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: metaURL))) as? [String: Any]
        guard meta?["finished"] as? Bool == true || meta?["stoppedByUser"] as? Bool == true else { return false }

        let logURL = subagents.appending(path: "agent-\(agent).jsonl")
        let metaDate = (try? metaURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let logDate = (try? logURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let metaDate, let logDate else { return true }

        return logDate <= metaDate.addingTimeInterval(resumeGrace)
    }
}
