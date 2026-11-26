import Foundation

extension TranscriptActivity {
    public func backgroundTasks(of live: LiveSession?, in transcript: URL) -> [SessionBackgroundTask] {
        let started = live?.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        let subagents = transcript.deletingPathExtension().appending(path: "subagents")
        let foreground = pending.compactMap { id, launch -> SessionBackgroundTask? in
            guard Self.agentTools.contains(launch.tool) || launch.requestsBackground else { return nil }

            let active = ["busy", "waiting"].contains(live?.status ?? "") && launch.started >= started
            var task = launch.backgroundTask(id: id, status: active ? .running : .finished)
            task.runsInForeground = task.kind == .agent && !launch.requestsBackground
            return task
        }
        let history = taskHistory.values.map { task in
            guard task.status == .running else { return task }

            var task = task
            if let id = task.agentID, let outcome = Self.subagentOutcome(agent: id, in: subagents) {
                task.status = outcome
            } else if live == nil || task.started < started {
                task.status = .finished
            }
            return task
        }
        return history + foreground
    }

    struct TaskCompletion: Sendable {
        let status: SessionBackgroundTask.Status
        let path: String?
        let result: String?

        init(status: SessionBackgroundTask.Status, path: String?, result: String?) {
            self.status = status
            self.path = path
            self.result = result
        }

        init?(_ notification: String) {
            guard let status = notification.firstMatch(of: /<status>\s*(\w+)\s*<\/status>/)?.1 else { return nil }

            let outcome: SessionBackgroundTask.Status
            switch status {
            case "completed": outcome = .completed
            case "failed": outcome = .failed
            case "stopped", "killed", "cancelled", "canceled": outcome = .stopped
            case "expired": outcome = .finished
            default: return nil
            }
            let summary = notification.firstMatch(of: /<summary>([^<]*)<\/summary>/)?.1.description
            let code = notification.firstMatch(of: /<exit-code>\s*(-?\d+)\s*<\/exit-code>/)?.1 ?? summary?.firstMatch(of: /exit code (-?\d+)/)?.1
            self.status = code.flatMap { Int($0) }.map(SessionBackgroundTask.Status.exit) ?? outcome
            path = notification.firstMatch(of: /<output-file>([^<]*)<\/output-file>/)?.1.description
            result = (notification.firstMatch(of: /<result>([\s\S]*?)<\/result>/)?.1.description ?? summary).map { String($0.prefix(16 << 10)) }
        }
    }

    mutating func finishTask(_ id: String, completion: TaskCompletion, at date: Date) {
        guard var task = taskHistory[id] else {
            earlyTaskCompletions[id] = completion
            return
        }
        guard task.started <= date else { return }

        switch (task.status, completion.status) {
        case (.running, _), (.finished, _), (_, .exit): task.status = completion.status
        default: break
        }
        if let path = completion.path, let file = Self.taskOutputFile(path, id: id) { task.outputFile = file }
        if let result = completion.result, !result.isEmpty { task.result = result }
        taskHistory[id] = task
    }

    static func taskOutputFile(_ path: String, id: String) -> URL? {
        guard path.hasPrefix("/"), id.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil else { return nil }

        let url = URL(filePath: path)
        return url.lastPathComponent == "\(id).output" ? url : nil
    }
}

extension TranscriptActivity.Launch {
    func backgroundTask(id: String, agentID: String? = nil, status: SessionBackgroundTask.Status = .running, result: String? = nil) -> SessionBackgroundTask {
        let kind: SessionBackgroundTask.Kind = TranscriptActivity.agentTools.contains(tool) ? .agent : .shell
        return SessionBackgroundTask(id: id, kind: kind, title: title, started: started, toolUseID: toolUseID, agentID: agentID, prompt: prompt ?? command, status: status, outputFile: output.flatMap { TranscriptActivity.taskOutputFile($0, id: id) }, result: result.map { String($0.prefix(16 << 10)) })
    }
}
