import Foundation

public enum PickerKey: Sendable, Equatable {
    case up, down, left, right, sessionOnly
}

public enum SessionPicker {
    public struct Outcome: Sendable, Equatable {
        public let model: ModelChoice?
        public let effort: EffortLevel?
        public let isSessionOnly: Bool
    }

    static let modelConfirmation = Array("<local-command-stdout>Set model to ".utf8)
    static let effortConfirmation = Array("<local-command-stdout>Set effort level to ".utf8)

    // The /model picker opens on the current entry and wraps; the entry list is Default, Opus, Fable, Sonnet, Haiku.
    public static func keys(from: ModelChoice, to: ModelChoice) -> [PickerKey] {
        let all = ModelChoice.allCases
        let count = all.count
        let forward = ((all.firstIndex(of: to) ?? 0) - (all.firstIndex(of: from) ?? 0) + count) % count
        let steps = forward <= count / 2 ? Array(repeating: PickerKey.down, count: forward) : Array(repeating: PickerKey.up, count: count - forward)
        return steps + [.sessionOnly]
    }

    // The /effort slider opens on the current level and stops at its ends.
    public static func keys(from: EffortLevel, to: EffortLevel) -> [PickerKey] {
        let all = EffortLevel.allCases
        let delta = (all.firstIndex(of: to) ?? 0) - (all.firstIndex(of: from) ?? 0)
        return Array(repeating: delta < 0 ? PickerKey.left : .right, count: abs(delta)) + [.sessionOnly]
    }

    public static func outcomes(in tail: Data, after date: Date) -> [Outcome] {
        tail.split(separator: UInt8(ascii: "\n")).compactMap { line in
            let isModel = line.range(of: Data(modelConfirmation)) != nil
            guard isModel || line.range(of: Data(effortConfirmation)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let text = message["content"] as? String,
                  let stamp = (object["timestamp"] as? String).flatMap({ try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }),
                  stamp >= date
            else { return nil }

            let isSessionOnly = text.contains("this session only")
            if isModel {
                let named = text.components(separatedBy: "Set model to `").last ?? ""
                let choice = named.hasPrefix("Default") || named.contains("(default)") ? ModelChoice.default : ModelChoice.allCases.first { named.localizedStandardContains($0.rawValue) }
                return Outcome(model: choice, effort: nil, isSessionOnly: isSessionOnly)
            }
            let word = text.components(separatedBy: "Set effort level to ").last?.prefix(while: \.isLetter)
            return Outcome(model: nil, effort: word.flatMap { EffortLevel(rawValue: String($0)) }, isSessionOnly: isSessionOnly)
        }
    }
}
