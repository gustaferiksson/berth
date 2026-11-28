@testable import BerthCore
import Foundation
import Testing

struct RemoteQuestionsTests {
    private let transcript = [
        #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Plan the export"}}"#,
        #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{"questions":[{"header":"Format","question":"Which format should the export use?","multiSelect":false,"options":[{"label":"CSV","description":"Opens in any spreadsheet"},{"label":"JSON","description":"Keeps nested fields"}]},{"header":"Fields","question":"Which fields should it include?","multiSelect":true,"options":[{"label":"Name"},{"label":"Email"},{"label":"Plan"}]}]}}]}}"#,
    ]

    private func questions() throws -> [RemoteQuestion] {
        let entries = TranscriptTail.entries(in: Data((transcript.joined(separator: "\n") + "\n").utf8), dropFirst: false, queue: []).entries
        let input = try JSONSerialization.jsonObject(with: Data(#require(entries.last { $0.name == "AskUserQuestion" }).text.utf8)) as? [String: Any]
        return try #require(RemoteQuestion.parse(input))
    }

    @Test func transcriptWithTwoQuestionsParsesBoth() throws {
        let parsed = try questions()

        #expect(parsed.map(\.header) == ["Format", "Fields"])
        #expect(parsed.map(\.isMultiSelect) == [false, true])
        #expect(parsed[0].options == [.init(label: "CSV", detail: "Opens in any spreadsheet"), .init(label: "JSON", detail: "Keeps nested fields")])
        #expect(parsed[1].options.map(\.label) == ["Name", "Email", "Plan"])
    }

    @Test func replaysTheDialogKeysForASingleAndAMultiSelectQuestion() throws {
        let keys = try RemoteQuestion.keys(answering: questions(), with: [[1], [0, 2]])

        #expect(keys == [.digit2, .digit1, .digit3, .arrowDown, .arrowDown, .arrowDown, .arrowDown, .enter, .enter])
    }

    @Test func aLoneSingleSelectQuestionSubmitsOnItsDigit() {
        let question = RemoteQuestion(id: 0, header: nil, text: "Which?", isMultiSelect: false, options: [.init(label: "A", detail: nil), .init(label: "B", detail: nil)])

        #expect(RemoteQuestion.keys(answering: [question], with: [[1]]) == [.digit2])
    }

    @Test func aLoneMultiSelectQuestionStillGetsAReviewEnter() {
        let question = RemoteQuestion(id: 0, header: nil, text: "Which?", isMultiSelect: true, options: [.init(label: "A", detail: nil), .init(label: "B", detail: nil)])

        #expect(RemoteQuestion.keys(answering: [question], with: [[1]]) == [.digit2, .arrowDown, .arrowDown, .arrowDown, .enter, .enter])
    }

    @Test func refusesAnswersThatDoNotFitTheQuestions() throws {
        let parsed = try questions()

        #expect(RemoteQuestion.keys(answering: parsed, with: [[0]]) == nil)
        #expect(RemoteQuestion.keys(answering: parsed, with: [[0, 1], [0]]) == nil)
        #expect(RemoteQuestion.keys(answering: parsed, with: [[2], [0]]) == nil)
    }

    @Test func questionsWithoutDigitKeysAreNotRepresentable() {
        let tenOptions = (1...10).map { #"{"label":"O\#($0)"}"# }.joined(separator: ",")

        #expect(RemoteQuestion.parse(["questions": [["question": "Which?", "options": []]]]) == nil)
        #expect(RemoteQuestion.parse(try? JSONSerialization.jsonObject(with: Data(#"{"questions":[{"question":"Which?","options":[\#(tenOptions)]}]}"#.utf8)) as? [String: Any]) == nil)
        #expect(RemoteQuestion.parse(nil) == nil)
    }

    @Test func permissionModeTravelsInTheActivityAndOlderPayloadsDecode() throws {
        let activity = RemoteActivity(tasks: [], context: nil, permissionMode: "plan")
        let decoded = try JSONDecoder().decode(RemoteActivity.self, from: JSONEncoder().encode(activity))
        let older = try JSONDecoder().decode(RemoteActivity.self, from: Data(#"{"tasks":[]}"#.utf8))

        #expect(decoded.permissionMode == "plan")
        #expect(older.permissionMode == nil)
    }

    @Test func downKeyRoundTrips() throws {
        let request = RemoteClientMessage.key(sessionID: "s", key: .arrowDown, waitingFor: "permission prompt", waitingSince: 5)
        guard case let .key(_, key, waitingFor, since) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(request)) else { throw CancellationError() }

        #expect(key == .arrowDown)
        #expect(waitingFor == "permission prompt")
        #expect(since == 5)
    }
}
