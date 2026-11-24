import Darwin
import Foundation

public enum TineError: Error, Equatable {
    case unavailable
    case noReply
}

public struct TineCompletion: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case subcommand, option, arg, file, folder, history, special, mixin, shortcut, generic
    }

    public struct Item: Equatable, Sendable {
        public let name: String
        public let description: String
        public let kind: Kind
        public let isDangerous: Bool
        public let matches: [Int]
        public let replacement: NSRange
        public let text: String
        public let caret: Int
    }

    public let isPending: Bool
    public let items: [Item]
}

public enum TineReply: Equatable, Sendable {
    case unsupported
    case completion(TineCompletion)
}

public struct TineRequest: Equatable, Sendable {
    public let draft: String
    public let cwd: String
    let line: String
    let cursor: Int
    let offset: Int

    public init?(draft: String, caret: Int, cwd: String) {
        let text = draft as NSString
        guard draft.hasPrefix("!"), caret >= 1, caret <= text.length else { return nil }

        let before = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let start = before.location == NSNotFound ? 1 : NSMaxRange(before)
        let after = text.range(of: "\n", range: NSRange(location: caret, length: text.length - caret))
        let end = after.location == NSNotFound ? text.length : after.location
        self.draft = draft
        self.cwd = cwd
        line = text.substring(with: NSRange(location: start, length: end - start))
        cursor = caret - start
        offset = start
    }

    public var wire: String {
        "complete\u{1f}\(cursor)\u{1f}\(cwd)\u{1f}\u{1f}\(line)"
    }

    public func parse(_ reply: Data) throws -> TineReply {
        guard reply.first == UInt8(ascii: "{") else { return .unsupported }

        let wire = try JSONDecoder().decode(Wire.self, from: reply)
        let items = wire.items.compactMap { item -> TineCompletion.Item? in
            guard item.edit.start >= 0, item.edit.end >= item.edit.start else { return nil }

            return TineCompletion.Item(
                name: item.name,
                description: item.description ?? "",
                kind: item.kind.flatMap(TineCompletion.Kind.init(rawValue:)) ?? .generic,
                isDangerous: item.dangerous ?? false,
                matches: item.matches ?? [],
                replacement: NSRange(location: item.edit.start + offset, length: item.edit.end - item.edit.start),
                text: item.edit.text,
                caret: item.edit.cursor + offset
            )
        }
        return .completion(TineCompletion(isPending: wire.pending ?? false, items: items))
    }

    private struct Wire: Decodable {
        struct Item: Decodable {
            struct Edit: Decodable {
                let start: Int
                let end: Int
                let text: String
                let cursor: Int
            }

            let name: String
            let description: String?
            let kind: String?
            let dangerous: Bool?
            let matches: [Int]?
            let edit: Edit
        }

        let pending: Bool?
        let items: [Item]
    }
}

public struct TineClient: Sendable {
    public static let bundleIdentifier = "dev.gustaf.tine"
    public static let defaultSocketPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/share/tine/tine.sock").path

    private let socketPath: String
    private let launch: @Sendable () -> Void

    @preconcurrency
    public init(socketPath: String = defaultSocketPath, launch: @escaping @Sendable () -> Void = Self.launchApp) {
        self.socketPath = socketPath
        self.launch = launch
    }

    public static func launchApp() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-g", "-b", bundleIdentifier]
        try? process.run()
    }

    public func complete(_ request: TineRequest) async throws -> TineReply {
        let descriptor = try await connect()
        defer { close(descriptor) }

        guard ControlSocket.writeLine(Data(request.wire.utf8), to: descriptor) else { throw TineError.noReply }

        return try await request.parse(readLine(from: descriptor))
    }

    private func connect() async throws -> Int32 {
        let deadline = Date.now.addingTimeInterval(2)
        var hasLaunched = false
        while true {
            try Task.checkCancellation()
            if let descriptor = dial() { return descriptor }

            if !hasLaunched {
                launch()
                hasLaunched = true
            }
            guard Date.now < deadline else { throw TineError.unavailable }

            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func dial() -> Int32? {
        guard var address = try? ControlSocket.address(of: socketPath) else { return nil }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }

        return descriptor
    }

    private func readLine(from descriptor: Int32) async throws -> Data {
        let deadline = Date.now.addingTimeInterval(3)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while Date.now < deadline {
            try Task.checkCancellation()
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 50) > 0 else { continue }

            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { break }

            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 0x0A) { return data.prefix(upTo: newline) }
        }
        guard !data.isEmpty else { throw TineError.noReply }

        return data
    }
}

#if DEBUG
public final class TineStubServer: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (String) -> String
    private var listener: Int32 = -1
    private var source: (any DispatchSourceRead)?

    @preconcurrency
    public init(path: String, handler: @escaping @Sendable (String) -> String) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        var address = try ControlSocket.address(of: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError.socket(errno) }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw ControlError.socket(code)
        }

        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
    }

    private func accept() {
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return }

        let handler = handler
        DispatchQueue.global().async {
            defer { close(connection) }

            guard let line = try? ControlSocket.readLine(from: connection, timeout: 5) else { return }

            _ = ControlSocket.writeLine(Data(handler(String(decoding: line, as: UTF8.self)).utf8), to: connection)
        }
    }
}
#endif
