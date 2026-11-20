import Foundation

public struct TurnStarts: Sendable, Equatable {
    private var starts: [String: Date] = [:]

    public init() {}

    public subscript(sessionID: String) -> Date? {
        starts[sessionID]
    }

    public mutating func update(live: [String: LiveSession], sessions: [String: SessionSummary]) {
        let previous = starts
        starts = live.reduce(into: [:]) { starts, entry in
            guard entry.value.status == "busy" || entry.value.status == "waiting", let session = sessions[entry.key] else { return }
            guard let remembered = previous[entry.key] else {
                starts[entry.key] = session.lastPrompt
                return
            }

            starts[entry.key] = max(remembered, session.lastTypedPrompt ?? remembered)
        }
    }
}
