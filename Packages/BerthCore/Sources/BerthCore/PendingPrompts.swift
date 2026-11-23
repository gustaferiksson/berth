import Foundation

public struct PendingPrompt: Equatable, Sendable {
    public let text: String
    public let sentAt: Date
    public let attachmentCount: Int
    public let baseline: Int?
    public var isFailed: Bool
    public var wasQueued = false

    public init(text: String, sentAt: Date, attachmentCount: Int = 0, baseline: Int? = nil, isFailed: Bool = false) {
        self.text = text
        self.sentAt = sentAt
        self.attachmentCount = attachmentCount
        self.baseline = baseline
        self.isFailed = isFailed
    }
}

public enum PendingPrompts {
    public static let grace: TimeInterval = 10
    public static var uploadPath: Regex<(Substring, Substring)> { /@\S*\/RemoteUploads\/[0-9A-Fa-f-]{36}\/(\S+)/ }
    public static var imageToken: Regex<Substring> { /\[Image #\d+\]/ }

    public static func reconcile(_ pending: [PendingPrompt], entries: [RemoteEntry], queued: [String], now: Date) -> [PendingPrompt] {
        pending.compactMap { prompt in
            guard !prompt.isFailed else { return prompt }

            let isRecorded = if let baseline = prompt.baseline {
                recordedCount(text: prompt.text, attachmentCount: prompt.attachmentCount, entries: entries) > baseline
            } else {
                entries.contains { $0.kind == .prompt && normalised($0.text).hasSuffix(normalised(prompt.text)) && ($0.date ?? .distantPast) >= prompt.sentAt.addingTimeInterval(-1) }
            }
            if isRecorded { return nil }

            var prompt = prompt
            if isQueued(prompt, queued: queued) {
                prompt.wasQueued = true
                return prompt
            }

            let isSuperseded = prompt.baseline == nil && entries.contains { $0.kind == .prompt && ($0.date ?? .distantPast) > prompt.sentAt.addingTimeInterval(1) }

            return prompt.wasQueued || isSuperseded || now.timeIntervalSince(prompt.sentAt) > grace ? nil : prompt
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

    private static func isQueued(_ prompt: PendingPrompt, queued: [String]) -> Bool {
        if queued.contains(prompt.text) { return true }
        guard prompt.baseline != nil else { return false }

        let text = normalised(prompt.text)
        return queued.contains { matches($0, text: text, attachmentCount: prompt.attachmentCount) }
    }

    private static func matches(_ entryText: String, text: String, attachmentCount: Int) -> Bool {
        let uploadPath = Self.uploadPath
        let imageToken = Self.imageToken
        let uploads = entryText.matches(of: uploadPath)
        let images = entryText.matches(of: imageToken)
        guard uploads.count + images.count == attachmentCount else { return false }

        return normalised(entryText) == text
    }

    static func normalised(_ text: String) -> String {
        text.replacing(uploadPath, with: "").replacing(imageToken, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
