import Foundation

public nonisolated enum RemoteQuestionsFeature {
    public static let name = "questions"
}

public nonisolated enum RemotePermissionModeFeature {
    public static let name = "permissionMode"
}

public nonisolated struct RemoteQuestion: Equatable, Sendable, Identifiable {
    public struct Option: Equatable, Sendable {
        public let label: String
        public let detail: String?

        public init(label: String, detail: String?) {
            self.label = label
            self.detail = detail
        }
    }

    public let id: Int
    public let header: String?
    public let text: String
    public let isMultiSelect: Bool
    public let options: [Option]

    public init(id: Int, header: String?, text: String, isMultiSelect: Bool, options: [Option]) {
        self.id = id
        self.header = header
        self.text = text
        self.isMultiSelect = isMultiSelect
        self.options = options
    }

    public static func parse(_ input: [String: Any]?) -> [Self]? {
        guard let questions = input?["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }

        var parsed: [Self] = []
        for (index, question) in questions.enumerated() {
            let options = (question["options"] as? [[String: Any]] ?? []).enumerated().map { optionIndex, option in
                Option(label: option["label"] as? String ?? "Option \(optionIndex + 1)", detail: option["description"] as? String)
            }
            guard let text = question["question"] as? String, (1...9).contains(options.count) else { return nil }

            parsed.append(Self(id: index, header: question["header"] as? String, text: text, isMultiSelect: question["multiSelect"] as? Bool == true, options: options))
        }
        return parsed
    }

    // Claude Code's dialog: a number key picks (single-select also advances) or toggles; multi-select then needs Down past the Other row onto Next or Submit, then Enter; a review tab takes one more Enter unless the only question is single-select.
    public static func keys(answering questions: [Self], with choices: [[Int]]) -> [RemoteKey]? {
        guard questions.count == choices.count else { return nil }

        var keys: [RemoteKey] = []
        for (question, picked) in zip(questions, choices) {
            let digits = picked.sorted().compactMap { index in
                question.options.indices.contains(index) ? RemoteKey(rawValue: "digit\(index + 1)") : nil
            }
            guard digits.count == picked.count, Set(picked).count == picked.count, question.isMultiSelect || digits.count == 1 else { return nil }

            keys += digits
            if question.isMultiSelect { keys += Array(repeating: .arrowDown, count: question.options.count + 1) + [.enter] }
        }
        if questions.count > 1 || questions[0].isMultiSelect { keys.append(.enter) }
        return keys
    }
}
