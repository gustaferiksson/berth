import Foundation

public enum PendingApproval: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let detail: String?
    }

    public struct Edit: Equatable, Sendable {
        public let old: String
        public let new: String
    }

    case permission(tool: String, target: String, detail: String?, edit: Edit?)
    case question(String, [Option])
    case plan(String)
    case loading
    case unrepresentable

    public static let permissionPrompt = "permission prompt"

    public static func resolve(waitingFor: String?, call: ToolCall?) -> Self {
        guard waitingFor == permissionPrompt else { return .unrepresentable }
        guard let call else { return .loading }

        let name = call.use.name ?? ""
        let input = (try? JSONSerialization.jsonObject(with: Data(call.use.text.utf8))) as? [String: Any]
        if name == "AskUserQuestion" {
            let questions = input?["questions"] as? [[String: Any]] ?? []
            guard questions.count == 1, questions[0]["multiSelect"] as? Bool != true, let question = questions[0]["question"] as? String else { return .unrepresentable }

            let options = (questions[0]["options"] as? [[String: Any]] ?? []).enumerated().map { index, option in
                Option(label: option["label"] as? String ?? "Option \(index + 1)", detail: option["description"] as? String)
            }
            return (1...9).contains(options.count) ? .question(question, options) : .unrepresentable
        }
        if name == "ExitPlanMode" {
            return (input?["plan"] as? String).map(Self.plan) ?? .unrepresentable
        }
        guard let target = call.use.command ?? call.use.filePath ?? input?["url"] as? String ?? (call.use.text.isEmpty ? nil : call.use.text) else { return .unrepresentable }

        let edit = call.use.newText.map { Edit(old: call.use.oldText ?? "", new: $0) }
        return .permission(tool: name, target: target, detail: call.use.detail.flatMap { $0.isEmpty ? nil : $0 }, edit: edit)
    }
}

public enum ConversationFallback {
    public static let startGrace: TimeInterval = 10
    public static let detailGrace: TimeInterval = 4

    public static func needsTerminal(live: LiveSession?, call: ToolCall?, tabAge: TimeInterval, now: Date) -> Bool {
        guard let live else { return tabAge > startGrace }
        guard live.status == "waiting" else { return false }

        switch PendingApproval.resolve(waitingFor: live.waitingFor, call: call) {
        case .unrepresentable: return true
        case .loading: return live.statusUpdatedAt.map { now.timeIntervalSince1970 - $0 / 1000 > detailGrace } ?? false
        case .permission, .question, .plan: return false
        }
    }

    public static func canLeaveTerminal(live: LiveSession?) -> Bool {
        guard let live else { return false }

        return live.status != "waiting"
    }
}
