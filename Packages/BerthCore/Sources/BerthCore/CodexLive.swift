import Foundation

public enum CodexRunState: Sendable {
    case working, needsInput, ready

    public init?(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~/") else { return nil }

        let label = trimmed.drop(while: { !$0.isLetter }).lowercased()
        if label.hasPrefix("thinking") || label.hasPrefix("working") {
            self = .working
        } else if label.hasPrefix("needs input") || label.hasPrefix("blocked") {
            self = .needsInput
        } else if label.hasPrefix("ready") {
            self = .ready
        } else {
            return nil
        }
    }
}

public enum CodexLive {
    public static func sessions(_ probe: LiveProbe) -> [LiveSession] {
        probe.tabs.compactMap { tab in
            guard !tab.sessionID.isEmpty else { return nil }

            let state = CodexRunState(title: tab.terminalTitle)
            let rollout = tab.transcript.flatMap { CodexRollout.turnState(of: $0) }
            let status = switch state {
            case .working: "busy"
            case .needsInput: "waiting"
            case .ready: "idle"
            case nil:
                if let rollout, rollout.isOpen, (0...300).contains(-rollout.modified.timeIntervalSinceNow) { "busy" } else { "idle" }
            }
            return LiveSession(
                pid: 0,
                sessionId: tab.sessionID,
                cwd: tab.cwd,
                kind: "tab",
                status: status,
                waitingFor: state == .needsInput ? "needs input" : nil,
                statusUpdatedAt: (rollout?.modified ?? tab.opened).timeIntervalSince1970 * 1000,
                startedAt: tab.opened.timeIntervalSince1970 * 1000,
                observesWaiting: state != nil
            )
        }
    }
}
