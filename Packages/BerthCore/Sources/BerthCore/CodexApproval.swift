import Foundation

extension CodexTranscript {
    private struct QuestionArguments: Decodable {
        struct Question: Decodable {
            struct Option: Decodable {
                let label: String
                let description: String?
            }

            let question: String
            let options: [Option]
        }

        let questions: [Question]
    }

    static func pendingApproval(_ url: URL) -> PendingApproval? {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = (try? handle.seekToEnd()).map(Int.init) else { return nil }

        defer { try? handle.close() }
        let decoder = JSONDecoder()
        var window = CodexRollout.tailBytes
        while true {
            let start = max(0, size - window)
            guard (try? handle.seek(toOffset: UInt64(max(0, start - 1)))) != nil,
                  let data = try? handle.read(upToCount: window + 1)
            else { return nil }

            let dropFirst = start > 0 && data.first != UInt8(ascii: "\n")
            var answered: Set<String> = []
            for line in data.split(separator: UInt8(ascii: "\n")).dropFirst(dropFirst ? 1 : 0).reversed() {
                guard line.range(of: Data("response_item".utf8)) != nil || CodexRollout.turnKeywords.contains(where: { line.range(of: $0) != nil }),
                      let record = try? decoder.decode(Record.self, from: Data(line))
                else { continue }

                let type = record.payload.type ?? ""
                if record.type == "event_msg", CodexRollout.turnEvents.contains(type) { return nil }
                guard record.type == "response_item", let id = record.payload.callID else { continue }

                if type == "function_call_output" || type == "custom_tool_call_output" {
                    answered.insert(id)
                } else if type == "function_call" || type == "custom_tool_call", !answered.contains(id) {
                    return approval(for: record.payload, decoder: decoder)
                }
            }
            if start == 0 || window >= CodexRollout.maxTailBytes { return nil }

            window *= 2
        }
    }

    private static func approval(for call: Payload, decoder: JSONDecoder) -> PendingApproval? {
        let name = call.name ?? ""
        let arguments = Data((call.arguments ?? "").utf8)
        if name == "request_user_input" {
            guard let questions = (try? decoder.decode(QuestionArguments.self, from: arguments))?.questions,
                  questions.count == 1, let question = questions.first, (1...9).contains(question.options.count)
            else { return .unrepresentable }

            return .question(question.question, question.options.map { .init(label: $0.label, detail: $0.description) })
        }

        let values = (try? decoder.decode(Arguments.self, from: arguments).strings) ?? [:]
        let input = call.input ?? ""
        let script = name == "exec" && call.type == "custom_tool_call"
        let commands = script ? scriptStrings(input, after: commandField, decoder: decoder) : []
        let isPatch = name == "apply_patch" || script && commands.isEmpty && input.range(of: #"\bapply_patch\s*\("#, options: .regularExpression) != nil
        guard isPatch || name == "exec" || execNames.contains(name) else { return nil }

        let target = if isPatch {
            values["patch"] ?? values["input"] ?? scriptStrings(input, after: #"(?:\bpatch\s*:\s*|\bapply_patch\s*\(\s*)"#, decoder: decoder).first ?? input
        } else {
            values["cmd"] ?? values["command"] ?? commands.joined(separator: "\n")
        }
        guard !target.isEmpty else { return .unrepresentable }

        let reason = values["justification"] ?? scriptStrings(input, after: #"\bjustification\s*:\s*"#, decoder: decoder).first
        return .permission(
            tool: isPatch ? "apply_patch" : "Bash",
            target: String(target.prefix(TranscriptTail.maxText)),
            detail: reason.map { String($0.prefix(TranscriptTail.maxDetail)) },
            edit: nil
        )
    }
}
