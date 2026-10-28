public enum ClaudeLaunch {
    public static let sessionVariable = "BERTH_SESSION_ID"
    public static let promptVariable = "BERTH_PROMPT"

    public enum Start: Sendable {
        case new, resume
    }

    public static func command(_ start: Start, prompt: String) -> String {
        let flag = start == .resume ? "--resume" : "--session-id"
        let argument = prompt.isEmpty ? "" : " -- \"$\(promptVariable)\""
        return "/bin/zsh -ilc 'claude \(flag) \"$\(sessionVariable)\"\(argument) || exec /bin/zsh -il'"
    }
}
