public enum ClaudeLaunch {
    public static let sessionVariable = "BERTH_SESSION_ID"
    public static let promptVariable = "BERTH_PROMPT"

    public static func command(resuming: Bool, hasPrompt: Bool) -> String {
        let flag = resuming ? "--resume" : "--session-id"
        let prompt = hasPrompt ? " -- \"$\(promptVariable)\"" : ""
        return "/bin/zsh -ilc 'claude \(flag) \"$\(sessionVariable)\"\(prompt) || exec /bin/zsh -il'"
    }
}
