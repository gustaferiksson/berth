public enum Agent: String, Sendable, Codable, Hashable {
    case claude, codex

    public var name: String { self == .codex ? "Codex" : "Claude" }
}
