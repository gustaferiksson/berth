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

        let harness = (tab(forSession: sessionID)?.agent ?? sessionsByID[sessionID]?.agent ?? .claude).harness
        if harness.liveSource == .tabSignals {
            let openFirst = "Open the session in a tab first, so the message wasn’t sent"
            guard let opened = tab(forSession: sessionID) else { return .refused(openFirst) }

            let name = harness.name
            let refusal = { () -> InputOutcome? in
                self.refreshLive()
                guard let live = self.liveBySession[sessionID] else { return nil }

                if live.status == "waiting" { return .refused("\(name) is waiting for an answer in the terminal, so the message wasn’t sent") }
                if live.status == "busy", !live.reportsWaiting { return .refused("\(name) is working, so the message wasn’t sent") }
                return nil
            }
            let remaining = 5 - Date.now.timeIntervalSince(opened.opened)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard tab(forSession: sessionID)?.id == opened.id else { return .refused(openFirst) }

            if let refused = refusal() { return refused }

            let paths = files.filter { !ConversationDraft.isImage($0) }.map { "@\($0.path)" }
            lastKeyInput = .now
            opened.terminal.paste(text: (paths + [text]).filter { !$0.isEmpty }.joined(separator: " "))
            try? await Task.sleep(for: .milliseconds(300))
            guard tab(forSession: sessionID)?.id == opened.id else { return .refused(openFirst) }

            if let refused = refusal() { return refused }

            opened.terminal.sendKey(.enter)
            return .sent
        }

        refreshLive()
        guard liveBySession[sessionID]?.status != "waiting" else { return .refused("\(harness.name) is waiting for an answer, so the message wasn’t sent") }

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
        guard let terminal = tab(forSession: sessionID)?.terminal, liveBySession[sessionID] != nil else { return .refused("\(harness.name) didn’t start for this session") }

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
        let tab = tab(forSession: sessionID)
        let harness = (tab?.agent ?? sessionsByID[sessionID]?.agent ?? .claude).harness
        guard let live = liveBySession[sessionID], live.status == "waiting", live.waitingFor == waitingFor, live.statusUpdatedAt == waitingSince else { return .refused("\(harness.name)’s question changed, so the key wasn’t sent") }
        guard let tab else { return .refused("\(harness.name) isn’t running in a Berth tab for this session") }

        let mappedKey = key == .escape ? harness.approvalKeys.deny : key
        if key == .escape, mappedKey != .escape, let readApproval = harness.readApproval {
            guard let url = sessionIndex(for: tab.agent).url(ofSession: sessionID), case .permission? = readApproval(url) else {
                return .refused("Answer \(harness.name) in the terminal")
            }
        }
        lastKeyInput = .now
        let press = switch mappedKey {
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
        tab.terminal.sendKey(press)
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
        if (tab(forSession: sessionID)?.agent ?? sessionsByID[sessionID]?.agent)?.harness.liveSource == .tabSignals {
            guard let terminal = tab(forSession: sessionID)?.terminal else { return .refused("Open the session in a tab first, so the key wasn’t sent") }

            lastKeyInput = .now
            terminal.sendKey(TerminalKeyPress(.escape))
            return .sent
        }

        refreshLive()
        guard liveBySession[sessionID]?.status == "busy", let terminal = tab(forSession: sessionID)?.terminal else { return .refused("Claude isn’t working in a Berth tab for this session") }

        lastKeyInput = .now
        terminal.sendKey(TerminalKeyPress(.escape))
        return .sent
    }

    func stopSubagentThroughTasksDialog(_ task: SessionBackgroundTask) async -> InputOutcome {
        guard let sessionID = sessionTab?.sessionID, let stop = TerminalKeyPress(typing: "x") else { return .refused("Claude isn’t running in a Berth tab for this session") }
        guard !submittingSessions.contains(sessionID) else { return .refused("The previous message is still being sent, so the subagent wasn’t stopped") }

        submittingSessions.insert(sessionID)
        defer { submittingSessions.remove(sessionID) }

        refreshLive()
        guard let terminal = tab(forSession: sessionID)?.terminal, let live = liveBySession[sessionID] else { return .refused("Claude isn’t running in a Berth tab for this session") }
        guard live.status == "idle" else { return .refused("Claude is busy or waiting, so the subagent wasn’t stopped") }
        guard SubagentStop.isSupported(version: live.version), let keys = SubagentStop.keys(stopping: task, among: backgroundTasks) else { return .refused("This version of Claude isn’t known to show the subagent list the same way, so the subagent wasn’t stopped") }

        for key in keys {
            refreshLive()
            guard liveBySession[sessionID]?.status != "waiting" else { return .refused("Claude started waiting for an answer, so the subagent may not have been stopped and the Tasks dialog may still be open in the terminal") }

            lastKeyInput = .now
            switch key {
            case let .command(text):
                terminal.paste(text: text)
                try? await Task.sleep(for: .milliseconds(300))

            case .enter:
                terminal.sendKey(.enter)
                try? await Task.sleep(for: .milliseconds(1200))

            case .down:
                terminal.sendKey(TerminalKeyPress(.arrowDown))
                try? await Task.sleep(for: .milliseconds(150))

            case .stop:
                terminal.sendKey(stop)
                try? await Task.sleep(for: .milliseconds(500))

            case .escape:
                guard liveBySession[sessionID]?.status == "idle" else { return .refused("Claude started working again, so the Tasks dialog may still be open in the terminal") }

                terminal.sendKey(TerminalKeyPress(.escape))
            }
        }

        for _ in 0..<25 {
            if backgroundTask(matching: task.id)?.status != .running { return .sent }

            try? await Task.sleep(for: .milliseconds(200))
        }
        return .refused("The keys were sent, but Claude hasn’t reported the subagent stopped. Check the Tasks pane.")
    }

    func recallQueued(_ text: String, in sessionID: String) async -> InputOutcome {
        refreshLive()
        guard liveBySession[sessionID]?.status == "busy", let terminal = tab(forSession: sessionID)?.terminal,
              let clear = TerminalKeyPress(typing: "u", modifiers: .ctrl)
        else { return .refused("Claude isn’t working in a Berth tab for this session, so the queue wasn’t pulled back") }

        lastKeyInput = .now
        terminal.sendKey(TerminalKeyPress(.arrowUp))
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<(2 * text.split(separator: "\n", omittingEmptySubsequences: false).count + 2) {
            terminal.sendKey(clear)
            try? await Task.sleep(for: .milliseconds(20))
        }
        return .sent
    }

    func cycleMode(_ sessionID: String) -> InputOutcome {
        refreshLive()
        guard let tab = tab(forSession: sessionID), tab.agent.harness.supports(.permissionModes) else { return .refused("Open the session in a tab first, so the key wasn’t sent") }
        guard liveBySession[sessionID]?.status != "waiting" else { return .refused("\(tab.agent.harness.name) is waiting for an answer, so the key wasn’t sent") }

        lastKeyInput = .now
        tab.terminal.sendKey(TerminalKeyPress(.tab, modifiers: .shift))
        return .sent
    }

    private func refusalWhileWaiting(_ sessionID: String) -> InputOutcome? {
        refreshLive()
        guard liveBySession[sessionID]?.status == "waiting" else { return nil }

        let name = (tab(forSession: sessionID)?.agent ?? sessionsByID[sessionID]?.agent ?? .claude).harness.name
        return .refused("\(name) started waiting for an answer, so the message wasn’t sent")
    }
}
