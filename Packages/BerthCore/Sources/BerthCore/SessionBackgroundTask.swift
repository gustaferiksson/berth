import Foundation

public struct SessionBackgroundTask: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable {
        case shell, agent, terminal, monitor
    }

    public enum Status: Equatable, Sendable {
        case running, completed, failed, stopped, finished, exit(Int)
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let started: Date
    public let toolUseID: String?
    public let agentID: String?
    public let prompt: String?
    public var status: Status
    public var outputFile: URL?
    public var result: String?

    public init(id: String, kind: Kind, title: String, started: Date, toolUseID: String? = nil, agentID: String? = nil, prompt: String? = nil, status: Status = .running, outputFile: URL? = nil, result: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.started = started
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.prompt = prompt
        self.status = status
        self.outputFile = outputFile
        self.result = result
    }

    public init(_ task: RemoteTask) {
        let kind: Kind = switch task.kind {
        case RemoteTask.agent: .agent
        case RemoteTask.monitor: .monitor
        default: .shell
        }
        self.init(id: task.id, kind: kind, title: task.title, started: task.started, toolUseID: task.toolUseID, agentID: kind == .agent ? task.id : nil, prompt: task.command, result: task.call?.phrase)
    }

    public func elapsed(at date: Date) -> Duration {
        .seconds(max(0, date.timeIntervalSince(started)).rounded(.down))
    }
}

public struct BackgroundTaskGroups: Sendable {
    public let running: [SessionBackgroundTask]
    public let finished: [SessionBackgroundTask]

    public init(_ tasks: [SessionBackgroundTask]) {
        let ordered = tasks.sorted { ($0.started, $0.id) > ($1.started, $1.id) }
        running = ordered.filter { $0.status == .running }
        finished = ordered.filter { $0.status != .running }
    }
}
