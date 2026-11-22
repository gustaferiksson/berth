@testable import BerthCore
import Foundation
import Testing

struct SessionPickerTests {
    private func effort(of lines: [String]) -> String? {
        var activity = TranscriptActivity()
        activity.apply(Data((lines.joined(separator: "\n") + "\n").utf8))
        return activity.effort
    }

    private func request(source: String, effort: String) -> String {
        #"{"type":"api-request","querySource":"\#(source)","params":{"model":"claude-example-1","output_config":{"effort":"\#(effort)"},"messages":[{"role":"user","content":"{\"output_config\":{\"effort\":\"low\"}}"}]}}"#
    }

    @Test func effortComesFromTheLastMainThreadRequest() {
        #expect(effort(of: [
            request(source: "repl_main_thread:outputStyle:Concise", effort: "high"),
            request(source: "agent:subagent", effort: "low"),
            request(source: "sdk", effort: "max"),
        ]) == "high")
        #expect(effort(of: [request(source: "repl_main_thread", effort: "medium"), request(source: "main_thread", effort: "xhigh")]) == "xhigh")
    }

    @Test func effortIgnoresBlobsEscapedTextAndUnknownLevels() {
        #expect(effort(of: [#"{"type":"api-request-blob","message":{"content":"x"}}"#, request(source: "repl_main_thread", effort: "turbo")]) == nil)
    }

    @Test func aSessionOnlyConfirmationSetsEffortAtOnce() {
        let confirmation = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set effort level to xhigh (this session only): Deeper</local-command-stdout>"}}"#
        #expect(effort(of: [request(source: "repl_main_thread", effort: "low"), confirmation]) == "xhigh")
    }

    @Test func contextCarriesEffortAndOldPeersStillDecode() throws {
        let old = #"{"model":"claude-example-1","date":0,"compactions":0}"#
        #expect(try JSONDecoder().decode(RemoteContext.self, from: Data(old.utf8)).effort == nil)
    }

    @Test func modelPickerKeysWrapTheShortWay() {
        #expect(SessionPicker.keys(from: .opus, to: .haiku) == [.up, .up, .sessionOnly])
        #expect(SessionPicker.keys(from: .default, to: .fable) == [.down, .down, .sessionOnly])
        #expect(SessionPicker.keys(from: .default, to: .haiku) == [.up, .sessionOnly])
        #expect(SessionPicker.keys(from: .haiku, to: .haiku) == [.sessionOnly])
    }

    @Test func effortSliderKeysStopAtTheEnds() {
        #expect(SessionPicker.keys(from: .medium, to: .max) == [.right, .right, .right, .sessionOnly])
        #expect(SessionPicker.keys(from: .high, to: .low) == [.left, .left, .sessionOnly])
    }

    @Test func confirmationsAreReadFromRecordsAfterTheKeys() throws {
        let start = try Date("2026-11-22T15:00:00.000Z", strategy: .iso8601)
        let lines = [
            #"{"type":"user","timestamp":"2026-11-22T14:00:00.000Z","message":{"content":"<local-command-stdout>Set model to `Haiku 5.5` for this session only</local-command-stdout>"}}"#,
            #"{"type":"user","timestamp":"2026-11-22T15:00:01.000Z","message":{"content":"<local-command-stdout>Set model to `Opus 5.5 (default)` for this session only</local-command-stdout>"}}"#,
            #"{"type":"user","timestamp":"2026-11-22T15:00:02.000Z","message":{"content":"<local-command-stdout>Set effort level to high and saved as your default for new sessions: x</local-command-stdout>"}}"#,
        ]
        let outcomes = SessionPicker.outcomes(in: Data(lines.joined(separator: "\n").utf8), after: start)
        #expect(outcomes == [
            SessionPicker.Outcome(model: .default, effort: nil, isSessionOnly: true),
            SessionPicker.Outcome(model: nil, effort: .high, isSessionOnly: false),
        ])
    }
}
