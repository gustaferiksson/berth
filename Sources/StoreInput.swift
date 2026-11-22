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

        let images = files.filter(ConversationDraft.isImage)
        let others = files.filter { !images.contains($0) }.map { "@\($0.path)" }
        let parts = text.split(separator: /\[Image #\d+\]/, omittingEmptySubsequences: false).map(String.init)
        lastKeyInput = .now
        if !images.isEmpty, parts.count == images.count + 1 {
            for (index, image) in images.enumerated() {
                if let refusal = refusalWhileWaiting(sessionID) { return refusal }

                let leading = index == 0 ? (others + [parts[0]]).filter { !$0.isEmpty }.joined(separator: " ") : parts[index]
                if !leading.isEmpty { terminal.paste(text: leading) }
                terminal.paste(text: image.path)
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let refusal = refusalWhileWaiting(sessionID) { return refusal }

            if !parts[images.count].isEmpty { terminal.paste(text: parts[images.count]) }
            try? await Task.sleep(for: .milliseconds(300))
            if let refusal = refusalWhileWaiting(sessionID) { return refusal }

            lastKeyInput = .now
            terminal.sendKey(.enter)
            return .sent
        }
        let message = (others + [text]).filter { !$0.isEmpty }.joined(separator: " ")
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

    func change(_ setting: RemoteSessionSetting, from current: RemoteSessionSetting, in sessionID: String) async -> InputOutcome {
        guard !submittingSessions.contains(sessionID) else { return .refused("The previous message is still being sent, so the change wasn’t made") }

        submittingSessions.insert(sessionID)
        defer { submittingSessions.remove(sessionID) }

        var position = current
        for _ in 0..<2 {
            refreshLive()
            guard liveBySession[sessionID]?.status == "idle" else { return .refused("Claude is busy or waiting, so the change wasn’t made") }
            guard let terminal = tab(forSession: sessionID)?.terminal, let url = index.url(ofSession: sessionID) else { return .refused("Claude isn’t running in a Berth tab for this session") }

            let keys: [PickerKey]
            switch (position, setting) {
            case let (.model(from), .model(to)): keys = SessionPicker.keys(from: from, to: to)
            case let (.effort(from), .effort(to)): keys = SessionPicker.keys(from: from, to: to)
            default: return .refused("Unknown setting")
            }
            let command = if case .model = setting { "/model" } else { "/effort" }
            let started = Date.now - 1

            lastKeyInput = .now
            terminal.paste(text: command)
            try? await Task.sleep(for: .milliseconds(300))
            terminal.sendKey(.enter)
            try? await Task.sleep(for: .milliseconds(1200))
            for key in keys {
                guard liveBySession[sessionID]?.status != "waiting" else { return .refused("Claude started waiting for an answer, so the change wasn’t finished") }

                terminal.sendKey(Self.press(key))
                try? await Task.sleep(for: .milliseconds(150))
            }

            let outcome = await pickerOutcome(in: url, since: started)
            guard let outcome else {
                terminal.sendKey(TerminalKeyPress(.escape))
                return .refused("Claude didn’t confirm the change, so nothing was changed")
            }
            guard outcome.isSessionOnly else { return .refused("Claude saved that as your default for new sessions instead of this session only") }

            switch (outcome.model, outcome.effort, setting) {
            case let (model?, _, .model(target)):
                if model == target { return .sent }
                position = .model(model)

            case let (_, effort?, .effort(target)):
                if effort == target { return .sent }
                position = .effort(effort)

            default:
                return .refused("Claude’s answer wasn’t understood, so the change may not have applied")
            }
        }
        return .refused("Claude ended up on a different setting than the one picked")
    }

    private static func press(_ key: PickerKey) -> TerminalKeyPress {
        switch key {
        case .up: TerminalKeyPress(.arrowUp)
        case .down: TerminalKeyPress(.arrowDown)
        case .left: TerminalKeyPress(.arrowLeft)
        case .right: TerminalKeyPress(.arrowRight)
        case .sessionOnly: TerminalKeyPress(typing: "s") ?? TerminalKeyPress(.escape)
        }
    }

    private func pickerOutcome(in url: URL, since date: Date) async -> SessionPicker.Outcome? {
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(200))
            let tail = await Task.detached { () -> Data? in
                guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.seekToEnd() else { return nil }

                defer { try? handle.close() }
                try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
                return try? handle.readToEnd()
            }.value
            if let outcome = tail.flatMap({ SessionPicker.outcomes(in: $0, after: date) }).flatMap(\.last) { return outcome }
        }
        return nil
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
