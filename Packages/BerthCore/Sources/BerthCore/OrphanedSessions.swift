public enum OrphanedSessions {
    public struct Process: Sendable, Hashable {
        public let parent: Int32
        public let hasTerminal: Bool

        public init(parent: Int32, hasTerminal: Bool) {
            self.parent = parent
            self.hasTerminal = hasTerminal
        }
    }

    public static func ids(live: [LiveSession], processes: [Int32: Process]) -> Set<String> {
        Set(live.filter { session in
            guard session.kind == "interactive", let process = processes[session.pid] else { return false }

            return process.parent == 1 && !process.hasTerminal
        }.map(\.sessionId))
    }
}
