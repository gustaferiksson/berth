public enum PullRequestState: String, Sendable {
    case open = "Open"
    case draft = "Draft"
    case merged = "Merged"
    case closed = "Closed"
}

public protocol PullRequestCandidate {
    var repository: String { get }
    var number: Int { get }
    var head: String? { get }
    var state: PullRequestState { get }
}

public enum PullRequestSelection {
    public static func order<Candidate: PullRequestCandidate>(_ candidates: [Candidate], currentRepository: String?, branches: [String]) -> [Candidate] {
        var seen: Set<String> = []
        let unique = candidates.filter { seen.insert("\($0.repository.lowercased())#\($0.number)").inserted }
        let current = currentRepository?.lowercased()
        let stateRanks: [PullRequestState: Int] = [.open: 0, .draft: 0, .merged: 1, .closed: 2]
        func key(_ item: (offset: Int, element: Candidate)) -> [Int] {
            [stateRanks[item.element.state] ?? 0, item.element.repository.lowercased() == current ? 0 : 1, item.element.head.map(branches.contains) == true ? 0 : 1, item.offset]
        }
        return unique.enumerated().sorted { key($0).lexicographicallyPrecedes(key($1)) }.map(\.element)
    }
}
