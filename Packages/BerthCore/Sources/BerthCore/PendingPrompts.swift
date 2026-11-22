import Foundation

public struct PendingPrompt: Equatable, Sendable {
    public let text: String
    public let sentAt: Date
    public var wasQueued = false

    public init(text: String, sentAt: Date) {
        self.text = text
        self.sentAt = sentAt
    }
}

public enum PendingPrompts {
    public static let grace: TimeInterval = 10

    // A prompt sent from the composer shows before Claude Code writes it down; the transcript takes over once it does
    public static func reconcile(_ pending: [PendingPrompt], entries: [RemoteEntry], queued: [String], now: Date) -> [PendingPrompt] {
        pending.compactMap { prompt in
            let isRecorded = entries.contains { $0.kind == .prompt && $0.text.hasSuffix(prompt.text) && ($0.date ?? .distantPast) >= prompt.sentAt.addingTimeInterval(-1) }
            if isRecorded { return nil }

            var prompt = prompt
            if queued.contains(prompt.text) {
                prompt.wasQueued = true
                return prompt
            }

            return prompt.wasQueued || now.timeIntervalSince(prompt.sentAt) > grace ? nil : prompt
        }
    }

    public static func shown(_ pending: [PendingPrompt], queued: [String]) -> [String] {
        queued + pending.map(\.text).filter { !queued.contains($0) }
    }
}
