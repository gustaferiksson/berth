public enum ClaudeLaunch {
    public static let sessionVariable = "BERTH_SESSION_ID"
    public static let promptVariable = "BERTH_PROMPT"

    public enum Start: Sendable {
        case new, resume, attach
    }

    public static func command(_ start: Start, prompt: String) -> String {
        let flag = switch start {
        case .new: "--session-id"
        case .resume: "--resume"
        case .attach: "attach"
        }
        let argument = prompt.isEmpty || start == .attach ? "" : " -- \"$\(promptVariable)\""
        return "/bin/zsh -ilc 'claude \(flag) \"$\(sessionVariable)\"\(argument) || exec /bin/zsh -il'"
    }
}
