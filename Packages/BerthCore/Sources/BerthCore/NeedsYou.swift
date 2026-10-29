public enum NeedsYou {
    public static func update(previous: Set<String>?, live: [LiveSession], inBerth: Set<String>) -> (waiting: Set<String>, needsYou: Set<String>, entered: [LiveSession]) {
        let waiting = live.filter { $0.status == "waiting" }
        let needsYou = waiting.filter { inBerth.contains($0.sessionId) }
        let entered = previous.map { previous in needsYou.filter { !previous.contains($0.sessionId) } } ?? []
        return (Set(waiting.map(\.sessionId)), Set(needsYou.map(\.sessionId)), entered)
    }
}
