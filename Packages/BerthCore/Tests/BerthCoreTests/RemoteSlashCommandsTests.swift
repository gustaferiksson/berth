import BerthCore
import Foundation
import Testing

struct RemoteSlashCommandsTests {
    @Test func commandMessagesRoundTrip() throws {
        let request = RemoteClientMessage.commands(sessionID: "s")
        guard case let .commands(sessionID) = try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(request)) else { throw CancellationError() }

        #expect(sessionID == "s")

        let commands = [
            RemoteSlashCommand(name: "/model", summary: "Change the model", source: "built-in", requiresArguments: true, argumentHint: "<model>"),
            RemoteSlashCommand(name: "/compare", summary: "Compare two revisions", source: "project", requiresArguments: false, argumentHint: nil),
        ]
        let reply = RemoteServerMessage.commands(sessionID: "s", commands: commands)
        guard case let .commands(replySessionID, decoded) = try JSONDecoder().decode(RemoteServerMessage.self, from: JSONEncoder().encode(reply)) else { throw CancellationError() }

        #expect(replySessionID == sessionID)
        #expect(decoded == commands)
    }

    @Test func discoveredCommandsKeepMetadataAcrossTheWire() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "remote-commands-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let folder = home.appending(path: "project")
        let userCommands = home.appending(path: ".claude/commands")
        let projectCommands = folder.appending(path: ".claude/commands")
        try FileManager.default.createDirectory(at: userCommands, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectCommands, withIntermediateDirectories: true)
        try "Compare two revisions.".write(to: projectCommands.appending(path: "compare.md"), atomically: true, encoding: .utf8)
        try "---\ndescription: Generate a coverage report.\nargument-hint: [suite]\n---\nPrivate command body".write(to: userCommands.appending(path: "coverage.md"), atomically: true, encoding: .utf8)

        let discovered = SlashCommand.load(home: home, folder: folder, harness: .claude)
        let data = try JSONEncoder().encode(discovered.map { RemoteSlashCommand($0) })
        let decoded = try JSONDecoder().decode([RemoteSlashCommand].self, from: data)

        #expect(decoded.suffix(2).elementsEqual([
            RemoteSlashCommand(name: "/compare", summary: "Compare two revisions.", source: "project", requiresArguments: false, argumentHint: nil),
            RemoteSlashCommand(name: "/coverage", summary: "Generate a coverage report.", source: "user", requiresArguments: false, argumentHint: "[suite]"),
        ]))
        #expect(decoded.first { $0.name == "/model" }?.requiresArguments == true)
        #expect(decoded.map { SlashCommand($0) } == discovered)
    }
}
