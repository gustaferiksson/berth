import Foundation

public enum SessionPins {
    public static func split(_ sessions: [SessionSummary], pinned: [String]) -> (pinned: [SessionSummary], rest: [SessionSummary], kept: [String]) {
        let byID = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        let kept = pinned.filter { byID[$0] != nil }
        let keptIDs = Set(kept)
        return (kept.compactMap { byID[$0] }, sessions.filter { !keptIDs.contains($0.id) }, kept)
    }

    public static func moving(_ pinned: [String], _ id: String, onto index: Int) -> [String] {
        guard let source = pinned.firstIndex(of: id) else { return pinned }
        var order = pinned
        order.remove(at: source)
        order.insert(id, at: min(max(index, 0), order.count))
        return order
    }
}
