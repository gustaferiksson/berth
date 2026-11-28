import Foundation

public nonisolated enum RemoteLiveActivityFeature {
    public static let name = "liveActivity"
}

public nonisolated struct LiveActivityState: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case working, waiting, finished
    }

    public static let startGrace: TimeInterval = 30
    public static let staleAfter = 8 * 3600
    public static let dismissAfter = 120

    public let status: Status
    public let since: Double

    public init(status: Status, since: Double) {
        self.status = status
        self.since = since
    }

    public init?(sessionStatus: String?, statusUpdatedAt: Double?, turnStart: Date?, now: Date) {
        switch sessionStatus {
        case "busy": self.init(status: .working, since: turnStart?.timeIntervalSince1970 ?? statusUpdatedAt.map { $0 / 1000 } ?? now.timeIntervalSince1970)
        case "waiting": self.init(status: .waiting, since: statusUpdatedAt.map { $0 / 1000 } ?? now.timeIntervalSince1970)
        default: return nil
        }
    }
}

public nonisolated enum LiveActivityStep: Equatable, Sendable {
    case keep
    case update(LiveActivityState)
    case end

    public static func next(current: LiveActivityState?, last: LiveActivityState.Status, hasBeenActive: Bool, age: TimeInterval) -> Self {
        guard let current else { return hasBeenActive || age > LiveActivityState.startGrace ? .end : .keep }

        return current.status == last ? .keep : .update(current)
    }
}
