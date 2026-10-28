public enum NeedsYou {
    public static func update(previous: Set<String>?, live: [LiveSession]) -> (waiting: Set<String>, entered: [LiveSession]) {
        let waiting = live.filter { $0.status == "waiting" }
        let entered = previous.map { previous in waiting.filter { !previous.contains($0.sessionId) } } ?? []
        return (Set(waiting.map(\.sessionId)), entered)
    }
}
