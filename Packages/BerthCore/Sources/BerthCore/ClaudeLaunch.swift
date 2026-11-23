public enum ClaudeLaunch {
    public static let sessionVariable = "BERTH_SESSION_ID"

    public typealias Start = LaunchStart

    public static let models = ["opus", "sonnet", "haiku"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    public static func command(_ start: Start, _ options: LaunchOptions = LaunchOptions()) -> String {
        let flag = switch start {
        case .new, .newInWorktree: "--session-id"
        case .resume: "--resume"
        case .attach: "attach"
        }
        let joins = start == .attach
        let model = options.model.flatMap { joins ? nil : " --model \($0)" } ?? ""
        let effort = options.effort.flatMap { joins ? nil : " --effort \($0)" } ?? ""
        return "/bin/zsh -ilc 'claude \(flag) \"$\(sessionVariable)\"\(start == .newInWorktree ? " -w" : "")\(model)\(effort) || exec /bin/zsh -il'"
    }
}
