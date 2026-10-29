public enum ClaudeLaunch {
    public static let sessionVariable = "BERTH_SESSION_ID"

    public enum Start: Sendable {
        case new, resume, attach
    }

    public static func command(_ start: Start) -> String {
        let flag = switch start {
        case .new: "--session-id"
        case .resume: "--resume"
        case .attach: "attach"
        }
        return "/bin/zsh -ilc 'claude \(flag) \"$\(sessionVariable)\" || exec /bin/zsh -il'"
    }
}
