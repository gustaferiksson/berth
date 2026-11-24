import Foundation

public struct PendingPrompt: Equatable, Sendable {
    public let text: String
    public let sentAt: Date
    public let attachmentCount: Int
    public let baseline: Int?
    public let promptBaseline: Int?
    public var isFailed: Bool
    public var wasQueued = false
    fileprivate var claimedEntryIDs: Set<String> = []

    public var shellCommand: String? {
        guard text.hasPrefix("!") else { return nil }

        let command = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    public init(text: String, sentAt: Date, attachmentCount: Int = 0, baseline: Int? = nil, promptBaseline: Int? = nil, isFailed: Bool = false) {
        self.text = text
        self.sentAt = sentAt
        self.attachmentCount = attachmentCount
        self.baseline = baseline
        self.promptBaseline = promptBaseline
        self.isFailed = isFailed
    }
}

public enum PendingPrompts {
    public static let grace: TimeInterval = 10
    public static var uploadPath: Regex<(Substring, Substring)> { /@\S*\/RemoteUploads\/[0-9A-Fa-f-]{36}\/(\S+)/ }

    public static func reconcile(_ pending: [PendingPrompt], entries: [RemoteEntry], queued: [String], now: Date) -> [PendingPrompt] {
        let sendOrder = pending.indices.filter { !pending[$0].isFailed }.sorted { pending[$0].sentAt < pending[$1].sentAt }
        guard !sendOrder.isEmpty else { return pending }

        let promptEntries = entries.filter { $0.kind == .prompt }
        var remaining = pending.map(Optional.some)
        var claimedEntryIDs = Set(pending.flatMap(\.claimedEntryIDs))

        for index in sendOrder {
            let prompt = pending[index]
            let text = normalised(prompt.text)
            guard !text.isEmpty else { continue }

            let earliest = prompt.sentAt.addingTimeInterval(-1)
            let match = if let command = prompt.shellCommand {
                promptEntries.first { !claimedEntryIDs.contains($0.id) && $0.name == "bash" && $0.text == command && ($0.date ?? .distantPast) >= earliest }
            } else if let baseline = prompt.baseline {
                promptEntries.lazy.filter { matches($0.text, text: text, attachmentCount: prompt.attachmentCount) }
                    .dropFirst(baseline).first { !claimedEntryIDs.contains($0.id) }
            } else {
                promptEntries.first { entry in
                    !claimedEntryIDs.contains(entry.id) && (entry.date ?? .distantPast) >= earliest && normalised(entry.text).contains(text)
                }
            }
            guard let match else { continue }

            claimedEntryIDs.insert(match.id)
            remaining[index] = nil
        }

        let humanEntries = promptEntries.filter { $0.name != "bash" }
        for index in sendOrder {
            guard var prompt = remaining[index] else { continue }

            if prompt.shellCommand != nil {
                if now.timeIntervalSince(prompt.sentAt) > grace { remaining[index] = nil }
                continue
            }

            if isQueued(prompt, queued: queued) {
                prompt.wasQueued = true
                remaining[index] = prompt
                continue
            }

            let earliest = prompt.sentAt.addingTimeInterval(-1)
            let match: RemoteEntry? = if let promptBaseline = prompt.promptBaseline {
                humanEntries.dropFirst(promptBaseline).first { !claimedEntryIDs.contains($0.id) }
            } else if prompt.baseline == nil {
                humanEntries.first { !claimedEntryIDs.contains($0.id) && ($0.date ?? .distantPast) >= earliest }
            } else {
                nil
            }
            if let match { claimedEntryIDs.insert(match.id) }
            if match != nil || prompt.wasQueued || now.timeIntervalSince(prompt.sentAt) > grace { remaining[index] = nil }
        }

        return remaining.compactMap { prompt in
            guard var prompt else { return nil }

            if !prompt.isFailed { prompt.claimedEntryIDs = claimedEntryIDs }
            return prompt
        }
    }

    public static func recordedCount(text: String, attachmentCount: Int, entries: [RemoteEntry]) -> Int {
        let text = normalised(text)
        return entries.count { $0.kind == .prompt && matches($0.text, text: text, attachmentCount: attachmentCount) }
    }

    public static func unqueued(_ pending: [PendingPrompt], queued: [String]) -> [PendingPrompt] {
        pending.filter { $0.isFailed || !isQueued($0, queued: queued) }
    }

    public static func shown(_ pending: [PendingPrompt], queued: [String]) -> [String] {
        queued + unqueued(pending, queued: queued).map(\.text)
    }

    public static func recall(_ queued: [String], pending: [PendingPrompt]) -> (text: String, pending: [PendingPrompt]) {
        (queued.joined(separator: "\n"), pending.filter { $0.isFailed || !isQueued($0, queued: queued) })
    }

    private static func isQueued(_ prompt: PendingPrompt, queued: [String]) -> Bool {
        if queued.contains(prompt.text) { return true }

        let text = normalised(prompt.text)
        return queued.contains { normalised($0) == text }
    }

    private static func matches(_ entryText: String, text: String, attachmentCount: Int) -> Bool {
        let uploadPath = Self.uploadPath
        let uploads = entryText.matches(of: uploadPath)
        let images = entryText.matches(of: PromptTextPart.imageToken)
        guard uploads.count + images.count == attachmentCount else { return false }

        return normalised(entryText) == text
    }

    static func normalised(_ text: String) -> String {
        text.replacing(uploadPath, with: "").replacing(PromptTextPart.imageToken, with: "").replacing(/<[^>]*>/, with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
