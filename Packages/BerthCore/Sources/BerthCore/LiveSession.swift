import Foundation

public struct LiveSession: Sendable, Hashable, Decodable {
    public enum Activity: Sendable, Hashable {
        case working
        case needsInput(String?)
        case idle
    }

    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let kind: String?
    public let status: String?
    public let waitingFor: String?
    public let statusUpdatedAt: Double?

    public var activity: Activity {
        if status == "busy" { return .working }
        if status == "waiting" { return .needsInput(waitingFor) }
        return .idle
    }

    public static func load(from directory: URL, isAlive: (Int32) -> Bool) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let sessions = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(LiveSession.self, from: Data(contentsOf: $0)) }
        return newestPerSession(sessions.filter { isAlive($0.pid) })
    }

    static func newestPerSession(_ sessions: [LiveSession]) -> [LiveSession] {
        Dictionary(grouping: sessions, by: \.sessionId).values.compactMap { group in
            group.max { ($0.statusUpdatedAt ?? 0) < ($1.statusUpdatedAt ?? 0) }
        }
    }
}
