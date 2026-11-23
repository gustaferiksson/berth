public enum Agent: String, Sendable, Codable, Hashable, CaseIterable {
    case claude, codex

    public var name: String { harness.name }
}
