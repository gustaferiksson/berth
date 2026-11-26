import Foundation

extension TranscriptActivity {
    static let watchMarkers = [
        "<command-name>", "<task-notification>", "<local-command-stdout>",
        #""session_end""#, #""session_resume""#, #""relocated""#, #""worktree-state""#,
        "[Request interrupted by user",
    ].map { Array($0.utf8) }
    static let branchKey = Array(#""gitBranch":""#.utf8)

    public func pullRequestWatch(of live: LiveSession?, now: Date) -> PullRequestWatch? {
        guard let live, live.status != nil, let watch = commandWatch, now < watch.expiresAt else { return nil }

        let started = live.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        return watch.since >= started ? watch : nil
    }

    static func watch(argument: Substring?, at date: Date) -> PullRequestWatch {
        if let argument, let number = Int(argument), number > 0 {
            return PullRequestWatch(number: number, since: date)
        }
        if let argument, let link = PullRequestLink.parse(String(argument)) {
            return PullRequestWatch(number: link.number, repository: link.repository.lowercased(), since: date)
        }
        return PullRequestWatch(number: nil, since: date)
    }

    mutating func updateWatch(_ object: [String: Any], at date: Date) {
        let type = object["type"] as? String
        let subtype = object["subtype"] as? String
        let branch = object["gitBranch"] as? String
        if ["session_end", "session_resume", "relocated"].contains(type)
            || type == "system" && ["session_end", "session_resume"].contains(subtype)
            || branch.map({ watchBranch != nil && watchBranch != $0 }) == true {
            stopWatch(at: date)
        }
        if type == "worktree-state" {
            let path = (object["worktreeSession"] as? [String: Any])?["worktreePath"] as? String ?? ""
            if let watchWorktree, path != watchWorktree { stopWatch(at: date) }
            watchWorktree = path
        }

        let origin = (object["origin"] as? [String: Any])?["kind"] as? String
        guard type == "user", origin == nil || origin == "human", object["isCompactSummary"] as? Bool != true else { return }

        let content = (object["message"] as? [String: Any])?["content"]
        let text = content as? String ?? (content as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if text.wholeMatch(of: /\[Request interrupted by user(?: for tool use)?\]/) != nil
            || text.firstMatch(of: /<local-command-stdout>\s*(?:Stopped watching|Stopped (?:the )?(?:PR |pull request )?watch)\b/) != nil {
            stopWatch(at: date)
        }
        let commandText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commandText.hasPrefix("<command-name>") || commandText.hasPrefix("<command-message>"), let name = commandText.firstMatch(of: /<command-name>\s*(\/[a-z]+)([^<]*)<\/command-name>/), name.2.isEmpty || name.2.first?.isWhitespace == true else { return }

        if ["/clear", "/resume", "/cd"].contains(name.1) {
            stopWatch(at: date)
            return
        }
        guard name.1 == "/ship" else { return }

        let arguments = text.firstMatch(of: /<command-args>([^<]*)<\/command-args>/)?.1 ?? name.2
        let argument = arguments.split(whereSeparator: \.isWhitespace).first
        if argument == "stop" {
            stopWatch(at: date)
        } else if date >= watchEndedAt {
            stopWatch(at: date)
            commandWatch = Self.watch(argument: argument, at: date)
            watchBranch = branch
        }
    }

    mutating func stopWatch(at date: Date) {
        watchEndedAt = max(watchEndedAt, date)
        if commandWatch.map({ $0.since <= date }) == true { commandWatch = nil }
        if commandWatch == nil { watchBranch = nil }
    }
}
