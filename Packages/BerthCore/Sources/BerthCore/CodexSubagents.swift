import Foundation

enum CodexSubagents {
    private struct Metadata: Decodable {
        struct Payload: Decodable {
            let id: String
            let source: Source?

            enum CodingKeys: String, CodingKey { case id, source }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                source = try? container.decode(Source.self, forKey: .source)
            }
        }

        let type: String
        let payload: Payload
    }

    private struct Source: Decodable {
        struct AgentSource: Decodable {
            let threadSpawn: Spawn
        }

        let subagent: AgentSource
    }

    private struct Spawn: Decodable {
        let parentThreadId: String
        let agentPath: String?
        let agentNickname: String?
        let agentRole: String?
    }

    private struct Launch {
        let id: String
        let callID: String?
        let path: String?
        let started: Date
        let arguments: [String: String]
    }

    static func tasks(root: URL, session: URL) -> [RemoteTask] {
        guard let parent = metadata(of: session)?.id else { return [] }

        return launches(in: session).compactMap { launch in
            guard let child = child(root: root, session: session, parent: parent, agentID: launch.id, launch: launch), !child.isFinished else { return nil }

            return RemoteTask(id: child.id, kind: RemoteTask.agent, title: child.description, started: launch.started, agentType: child.agentType, toolUseID: launch.callID)
        }.sorted { $0.started < $1.started }
    }

    static func locate(root: URL, session: URL, agentID: String?, toolUseID: String?) -> Subagent? {
        guard agentID != nil || toolUseID != nil, let parent = metadata(of: session)?.id else { return nil }

        let launches = launches(in: session)
        let launch = launches.last { (agentID != nil && $0.id == agentID) || (toolUseID != nil && $0.callID == toolUseID) }
        guard let id = launch?.id ?? agentID else { return nil }

        return child(root: root, session: session, parent: parent, agentID: id, launch: launch)
    }

    static func spawnMessage(_ arguments: [String: String]) -> String? {
        let message = arguments["message"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.flatMap { $0.isEmpty || $0.hasPrefix("gAAAA") ? nil : String($0.prefix(TranscriptTail.maxDetail)) }
    }

    private static func child(root: URL, session: URL, parent: String, agentID: String, launch: Launch?) -> Subagent? {
        guard UUID(uuidString: agentID) != nil else { return nil }

        let suffix = "-\(agentID.lowercased()).jsonl"
        let make = { (file: URL) -> Subagent? in
            guard file.lastPathComponent.hasPrefix("rollout-"), file.lastPathComponent.lowercased().hasSuffix(suffix),
                  let meta = metadata(of: file), meta.id.caseInsensitiveCompare(agentID) == .orderedSame,
                  let spawn = meta.source?.subagent.threadSpawn, spawn.parentThreadId == parent,
                  let turn = CodexRollout.turnState(of: file) else { return nil }

            let path = launch?.path ?? spawn.agentPath
            let title = launch.flatMap { spawnMessage($0.arguments) } ?? spawn.agentNickname ?? path ?? "Agent"
            let role = spawn.agentRole ?? launch?.arguments["agent_type"] ?? path.map { String($0.split(separator: "/").last ?? "") } ?? "Agent"
            return Subagent(id: meta.id, description: title, agentType: role, isFinished: !turn.isOpen, url: file)
        }
        let directory = session.deletingLastPathComponent()
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
           let child = files.lazy.compactMap(make).first { return child }

        guard let files = FileManager.default.enumerator(at: root.appending(path: "sessions"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }

        for case let file as URL in files where file.deletingLastPathComponent() != directory {
            if let child = make(file) { return child }
        }
        return nil
    }

    private static func metadata(of url: URL) -> Metadata.Payload? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }

        defer { try? handle.close() }
        var line = Data()
        while line.count < CodexRollout.maxTailBytes, let chunk = try? handle.read(upToCount: CodexRollout.headBytes), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(chunk.prefix(upTo: newline))
                break
            }
            line.append(chunk)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let meta = try? decoder.decode(Metadata.self, from: line), meta.type == "session_meta" else { return nil }

        return meta.payload
    }

    private static func launches(in url: URL) -> [Launch] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }

        defer { try? handle.close() }
        let decoder = JSONDecoder()
        let spawn = Data("spawn_agent".utf8)
        let activity = Data("SubAgentActivity".utf8)
        var pending: [String: [String: String]] = [:]
        var launches: [String: Launch] = [:]
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: CodexRollout.headBytes), !chunk.isEmpty {
            buffer.append(chunk)
            guard let newline = buffer.lastIndex(of: UInt8(ascii: "\n")) else { continue }

            let lines = buffer.prefix(upTo: newline)
            if lines.range(of: spawn) != nil || lines.range(of: activity) != nil {
                for line in lines.split(separator: UInt8(ascii: "\n")) {
                    guard line.range(of: spawn) != nil || line.range(of: activity) != nil,
                          let record = try? decoder.decode(CodexTranscript.Record.self, from: Data(line))
                    else { continue }

                    let payload = record.payload
                    if record.type == "response_item", payload.type == "function_call", payload.name == "spawn_agent", let id = payload.callID, let arguments = payload.arguments {
                        pending[id] = (try? decoder.decode(CodexTranscript.Arguments.self, from: Data(arguments.utf8)))?.strings
                    } else if record.type == "event_msg", payload.type == "item_completed", let item = payload.item,
                              item.type == "SubAgentActivity", item.kind == "started", let id = item.agentThreadID, let date = CodexRollout.date(record.timestamp) {
                        let arguments = item.id.flatMap { pending.removeValue(forKey: $0) } ?? [:]
                        launches[id] = Launch(id: id, callID: item.id, path: item.agentPath, started: date, arguments: arguments)
                    }
                }
            }
            buffer.removeSubrange(...newline)
        }
        return Array(launches.values)
    }
}
