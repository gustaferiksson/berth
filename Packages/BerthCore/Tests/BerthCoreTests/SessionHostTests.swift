@testable import BerthCore
import Darwin
import Foundation
import Testing

struct SessionHostTests {
    @Test func framesSurviveSplitReads() throws {
        let frames: [HostFrame] = [.attach(cols: 120, rows: 40), .input([1, 2, 3]), .resize(cols: 80, rows: 24), .hangUp, .probe, .output(Array(repeating: 7, count: 70000)), .exit(-9), .replaced, .hello(host: 1234, child: 5678)]
        let stream = frames.flatMap { $0.encoded() }
        var decoder = HostFrameDecoder()
        var decoded: [HostFrame] = []
        for start in stride(from: 0, to: stream.count, by: 7) {
            decoded += try decoder.decode(Array(stream[start..<min(start + 7, stream.count)]))
        }

        #expect(decoded == frames)
    }

    @Test func decoderRejectsOversizedAndUnknownFrames() {
        var decoder = HostFrameDecoder()
        #expect(throws: SessionHostError.malformedFrame) { try decoder.decode([0x81, 0xFF, 0xFF, 0xFF, 0xFF]) }

        var other = HostFrameDecoder()
        #expect(throws: SessionHostError.malformedFrame) { try other.decode([0x42, 0, 0, 0, 0]) }

        var old = HostFrameDecoder()
        #expect(throws: SessionHostError.unsupportedVersion(9)) { try old.decode([0x01, 0, 0, 0, 5, 9, 0, 80, 0, 24]) }
    }

    @Test func ringKeepsTheNewestBytes() {
        var ring = ScrollbackRing(capacity: 10)
        ring.append(Self.bytes(0..<8))
        #expect(ring.contents == Self.bytes(0..<8))

        ring.append(Self.bytes(8..<15))
        #expect(ring.contents == Self.bytes(5..<15))

        for start in stride(from: 15, to: 100, by: 5) { ring.append(Self.bytes(start..<(start + 5))) }
        #expect(ring.contents == Self.bytes(90..<100))
    }

    @Test func socketPathsUseAShortStableName() throws {
        let id = "8D0F2A52-1C4B-4E0B-9C4A-3B3F0A3A9D11"
        #expect(try SessionHost.socketPath(directory: "/tmp/h", id: id) == "/tmp/h/8d0f2a521c4b.sock")
        #expect(throws: SessionHostError.pathTooLong) { try SessionHost.socketPath(directory: "/tmp/" + String(repeating: "x", count: 120), id: id) }
    }

    @Test func hostOutlivesItsClientReplaysScrollbackAndEndsOnHangUp() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let id = UUID().uuidString
        try Self.start(directory: directory, id: id, command: "echo first-marker; exec cat")
        let path = try SessionHost.socketPath(directory: directory, id: id)
        let identity = try #require(SessionHost.probe(socketPath: path))

        let first = try HostConnection(socketPath: path)
        first.send(.attach(cols: 80, rows: 24))
        #expect(try Self.read(first, until: "first-marker").contains("first-marker"))

        first.send(.input(Array("typed-line\n".utf8)))
        #expect(try Self.read(first, until: "typed-line").contains("typed-line"))

        let second = try HostConnection(socketPath: path)
        second.send(.attach(cols: 100, rows: 30))
        let replay = try Self.read(second, until: "typed-line")
        #expect(replay.contains("first-marker") && replay.contains("typed-line"))
        #expect(try Self.frames(first).contains(.replaced))

        #expect(SessionHost.probe(socketPath: path)?.child == identity.child)
        #expect(kill(identity.child, 0) == 0)

        SessionHost.hangUp(socketPath: path)
        #expect(Self.eventually { kill(identity.child, 0) != 0 && kill(identity.host, 0) != 0 })
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func clientsReceiveTheChildsExitStatus() throws {
        let directory = try Self.shortDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let id = UUID().uuidString
        try Self.start(directory: directory, id: id, command: "sleep 1; exit 3")
        let connection = try HostConnection(socketPath: try SessionHost.socketPath(directory: directory, id: id))
        connection.send(.attach(cols: 80, rows: 24))

        var status: Int32?
        let deadline = Date.now.addingTimeInterval(10)
        while status == nil, Date.now < deadline {
            guard let frames = try connection.receive(timeout: 0.2) else { break }

            for case let .exit(code) in frames { status = code }
        }

        #expect(status == 3)
    }

    private static func bytes(_ range: Range<Int>) -> [UInt8] {
        range.map { UInt8($0) }
    }

    private static func shortDirectory() throws -> String {
        let directory = "/tmp/bh-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func start(directory: String, id: String, command: String) throws {
        let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tool = try #require(["out/Products/Debug", "debug"].map { package.appending(path: ".build/\($0)/berth-host") }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        let process = Process()
        process.executableURL = tool
        process.arguments = ["start", directory, id, command]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private static func frames(_ connection: HostConnection) throws -> [HostFrame] {
        try connection.receive(timeout: 1) ?? []
    }

    private static func read(_ connection: HostConnection, until needle: String) throws -> String {
        var text = ""
        let deadline = Date.now.addingTimeInterval(10)
        while !text.contains(needle), Date.now < deadline {
            guard let frames = try connection.receive(timeout: 0.2) else { break }

            for case let .output(bytes) in frames { text += String(decoding: bytes, as: UTF8.self) }
        }
        return text
    }

    private static func eventually(_ condition: () -> Bool) -> Bool {
        for _ in 0..<100 {
            if condition() { return true }

            usleep(50000)
        }
        return false
    }
}
