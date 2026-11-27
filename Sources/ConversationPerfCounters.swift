import Foundation

enum ConversationPerfCounters {
    nonisolated(unsafe) private static var totals: [String: Double] = [:]

    static func time<T>(_ name: String, _ body: () -> T) -> T {
        #if DEBUG
            let start = ContinuousClock.now
            defer { totals[name, default: 0] += Double((ContinuousClock.now - start).components.attoseconds) / 1e15 }
        #endif
        return body()
    }

    static func drain() -> String {
        defer { totals = [:] }
        return totals.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.1f", $0.value)) ms" }.joined(separator: ", ")
    }
}
