import Foundation

public enum CodexLaunch {
    public typealias Start = LaunchStart

    public static func command(_ start: Start, _ options: LaunchOptions) -> String {
        let validValue = /[A-Za-z0-9._-]+/
        let model = options.model.flatMap { $0.wholeMatch(of: validValue) == nil ? nil : " -m \($0)" } ?? ""
        let effort = options.effort.flatMap { $0.wholeMatch(of: validValue) == nil ? nil : " -c model_reasoning_effort=\($0)" } ?? ""
        let launch = start == .newInWorktree ? #"wt switch --create "codex-$(date +%m%d-%H%M%S)" --no-cd -x codex --"# : "codex"
        let resumes = start == .resume || start == .attach
        let resume = resumes ? " resume \"$\(ClaudeLaunch.sessionVariable)\"" : ""
        return #"/bin/zsh -ilc '\#(launch) -c "tui.terminal_title=[\"spinner\",\"run-state\"]"\#(model)\#(effort)\#(resume) || exec /bin/zsh -il'"#
    }

    public static func claim(for opened: Date, cwd: String, in sessions: [SessionSummary], excluding claimed: Set<String>) -> SessionSummary? {
        let candidates = sessions
            .filter { session in
                session.agent == .codex && !claimed.contains(session.id)
                    && session.startedAt.map { $0 >= opened } == true
            }
            .sorted { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }
        if let exact = candidates.first(where: { $0.cwd == cwd }) { return exact }
        guard !candidates.isEmpty else { return nil }

        let repository = RepositoryRoot.resolve(cwd)
        return candidates.first { session in
            guard let worktree = RepositoryRoot.worktree(containing: session.cwd) else { return false }

            return worktree.identity != worktree.folder && worktree.identity == repository
        }
    }
}
