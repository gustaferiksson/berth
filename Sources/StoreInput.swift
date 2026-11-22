import BerthCore
import Foundation
import GhosttyTerminal

enum InputOutcome: Equatable {
    case sent
    case refused(String)
}

extension Store {
    func submit(_ text: String, files: [URL], to sessionID: String) async -> InputOutcome {
        guard !submittingSessions.contains(sessionID) else { return .refused("The previous message is still being sent or the session is starting, so this one wasn’t sent") }

        submittingSessions.insert(sessionID)
        defer { submittingSessions.remove(sessionID) }

        guard sessionsByID[sessionID] != nil || tab(forSession: sessionID) != nil else { return .refused("Unknown session") }

        refreshLive()
        guard liveBySession[sessionID]?.status != "waiting" else { return .refused("Claude is waiting for an answer, so the message wasn’t sent") }

        if tab(forSession: sessionID) == nil || liveBySession[sessionID] == nil {
            if isLockedElsewhere(liveBySession[sessionID]), tab(forSession: sessionID) == nil {
                return .refused("This session is running in another terminal, so it is read-only here")
            }
            activate(.session(sessionID))
            let deadline = Date.now + 30
            while Date.now < deadline, tab(forSession: sessionID) == nil || liveBySession[sessionID] == nil {
                try? await Task.sleep(for: .milliseconds(250))
                refreshLive()
            }
            try? await Task.sleep(for: .seconds(2))
        }

        refreshLive()
        guard let terminal = tab(forSession: sessionID)?.terminal, liveBySession[sessionID] != nil else { return .refused("Claude didn’t start for this session") }

        let images = files.filter { ["jpg", "jpeg", "png", "gif", "webp"].contains($0.pathExtension.lowercased()) }
        let message = (files.filter { !images.contains($0) }.map { "@\($0.path)" } + [text]).filter { !$0.isEmpty }.joined(separator: " ")
        lastKeyInput = .now
        for image in images {
            if let refusal = refusalWhileWaiting(sessionID) { return refusal }

            terminal.paste(text: image.path)
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let refusal = refusalWhileWaiting(sessionID) { return refusal }

        terminal.paste(text: images.isEmpty ? message : " \(message)")
        if !images.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        if let refusal = refusalWhileWaiting(sessionID) { return refusal }

        lastKeyInput = .now
        terminal.sendKey(.enter)
        return .sent
    }

    func press(_ key: RemoteKey, in sessionID: String, answering waitingFor: String?, since waitingSince: Double?) -> InputOutcome {
        refreshLive()
        guard let live = liveBySession[sessionID], live.status == "waiting", live.waitingFor == waitingFor, live.statusUpdatedAt == waitingSince else { return .refused("Claude’s question changed, so the key wasn’t sent") }
        guard let terminal = tab(forSession: sessionID)?.terminal else { return .refused("Claude isn’t running in a Berth tab for this session") }

        lastKeyInput = .now
        let press = switch key {
        case .enter: TerminalKeyPress(.enter)
        case .escape: TerminalKeyPress(.escape)
        case .shiftTab: TerminalKeyPress(.tab, modifiers: .shift)
        case .digit1: TerminalKeyPress(.digit1)
        case .digit2: TerminalKeyPress(.digit2)
        case .digit3: TerminalKeyPress(.digit3)
        case .digit4: TerminalKeyPress(.digit4)
        case .digit5: TerminalKeyPress(.digit5)
        case .digit6: TerminalKeyPress(.digit6)
        case .digit7: TerminalKeyPress(.digit7)
        case .digit8: TerminalKeyPress(.digit8)
        case .digit9: TerminalKeyPress(.digit9)
        }
        terminal.sendKey(press)
        return .sent
    }

    func interrupt(_ sessionID: String) -> InputOutcome {
        refreshLive()
        guard liveBySession[sessionID]?.status == "busy", let terminal = tab(forSession: sessionID)?.terminal else { return .refused("Claude isn’t working in a Berth tab for this session") }

        lastKeyInput = .now
        terminal.sendKey(TerminalKeyPress(.escape))
        return .sent
    }

    private func refusalWhileWaiting(_ sessionID: String) -> InputOutcome? {
        refreshLive()
        guard liveBySession[sessionID]?.status == "waiting" else { return nil }

        return .refused("Claude started waiting for an answer, so the message wasn’t sent")
    }
}
