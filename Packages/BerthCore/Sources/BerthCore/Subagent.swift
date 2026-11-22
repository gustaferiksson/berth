import Foundation

public struct Subagent: Identifiable, Sendable {
    public let id: String
    public let description: String
    public let agentType: String
    public let isFinished: Bool
    public let url: URL

    private struct Metadata: Decodable {
        let description: String?
        let agentType: String?
        let toolUseId: String?
        let finished: Bool?
    }

    public static func locate(session: URL, agentID: String?, toolUseID: String?) -> Self? {
        let directory = session.deletingPathExtension().appending(path: "subagents")
        let decoder = JSONDecoder()
        if let agentID, !agentID.isEmpty, !agentID.contains("/"), agentID != ".", agentID != ".." {
            let url = directory.appending(path: "agent-\(agentID).jsonl")
            if FileManager.default.fileExists(atPath: url.path) {
                let metadata = (try? Data(contentsOf: directory.appending(path: "agent-\(agentID).meta.json"))).flatMap { try? decoder.decode(Metadata.self, from: $0) }
                return Self(id: agentID, description: metadata?.description ?? "Agent", agentType: metadata?.agentType ?? "Agent", isFinished: metadata?.finished == true, url: url)
            }
        }
        guard let toolUseID, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.lastPathComponent.hasPrefix("agent-") && file.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: file), let metadata = try? decoder.decode(Metadata.self, from: data), metadata.toolUseId == toolUseID else { continue }

            let id = String(file.lastPathComponent.dropFirst("agent-".count).dropLast(".meta.json".count))
            let url = directory.appending(path: "agent-\(id).jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            return Self(id: id, description: metadata.description ?? "Agent", agentType: metadata.agentType ?? "Agent", isFinished: metadata.finished == true, url: url)
        }
        return nil
    }
}
