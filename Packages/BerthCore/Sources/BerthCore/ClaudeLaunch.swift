public enum ClaudeLaunch {
    public static let sessionVariable = "BERTH_SESSION_ID"

    public enum Start: Sendable {
        case new, newInWorktree, resume, attach
    }

    public static func command(_ start: Start) -> String {
        let flag = switch start {
        case .new, .newInWorktree: "--session-id"
        case .resume: "--resume"
        case .attach: "attach"
        }
        return "/bin/zsh -ilc 'claude \(flag) \"$\(sessionVariable)\"\(start == .newInWorktree ? " -w" : "") || exec /bin/zsh -il'"
    }
}
