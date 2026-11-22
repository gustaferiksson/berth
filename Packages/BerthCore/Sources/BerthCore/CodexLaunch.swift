import Foundation

public enum CodexLaunch {
    public typealias Start = LaunchStart

    public static func command(_ start: Start) -> String {
        let resumes = start == .resume || start == .attach
        let resume = resumes ? " resume \"$\(ClaudeLaunch.sessionVariable)\"" : ""
        return #"/bin/zsh -ilc 'codex -c "tui.terminal_title=[\"run-state\"]"\#(resume) || exec /bin/zsh -il'"#
    }

    public static func claim(for opened: Date, cwd: String, in sessions: [SessionSummary], excluding claimed: Set<String>) -> SessionSummary? {
        sessions
            .filter { session in
                session.agent == .codex && session.cwd == cwd && !claimed.contains(session.id)
                    && session.startedAt.map { $0 >= opened } == true
            }
            .min { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }
    }
}
