import Foundation

public struct ReviewEditBuffer: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case current
        case conflict
    }

    public private(set) var base: String
    public private(set) var incoming: String?

    public var hasConflict: Bool { incoming != nil }

    public init(base: String) {
        self.base = base
    }

    public mutating func read(disk: String, draft: String?) -> Outcome {
        guard let draft, draft != disk, disk != base else {
            base = disk
            incoming = nil
            return .current
        }

        incoming = disk
        return .conflict
    }

    public mutating func acceptIncoming() {
        guard let incoming else { return }

        base = incoming
        self.incoming = nil
    }
}
