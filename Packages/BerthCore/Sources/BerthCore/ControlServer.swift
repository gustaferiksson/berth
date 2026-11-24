import Darwin
import Foundation

/// One JSON request line in, one JSON response line out, per connection. Only the owner's processes holding the token get through.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    static let maxRequest = 1 << 20

    private let path: String
    private let token: String
    private let handler: Handler
    private var listener: Int32 = -1
    private var source: (any DispatchSourceRead)?

    public init(path: String, token: String, handler: @escaping Handler) {
        self.path = path
        self.token = token
        self.handler = handler
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory, 0o700)
        unlink(path)
        var address = try ControlSocket.address(of: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError.socket(errno) }

        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
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

        var enabled: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let handler = handler
        let token = token
        Task.detached {
            defer { close(connection) }

            let response = await Self.respond(on: connection, token: token, handler: handler)
            _ = ControlSocket.writeLine(try? JSONEncoder().encode(response), to: connection)
        }
    }

    private static func respond(on connection: Int32, token: String, handler: Handler) async -> ControlResponse {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0, uid == geteuid() else { return .failure("Not the owner of this Berth") }
        guard let line = try? ControlSocket.readLine(from: connection, timeout: 5), let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            return .failure("Malformed request")
        }
        guard request.token == token else { return .failure("Wrong token: this tab holds an out-of-date Berth token (control was switched off and on, or the tab predates saved tokens). Open a new tab to use berth here.") }

        return await handler(request)
    }
}

public enum ControlClient {
    /// Sends one request and waits for the reply (no timeout: wait replies when its tab ends).
    public static func send(_ request: ControlRequest, socketPath: String) throws -> ControlResponse {
        var address = try ControlSocket.address(of: socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlError.socket(errno) }

        defer { close(descriptor) }

        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ControlError.socket(errno) }
        guard try ControlSocket.writeLine(JSONEncoder().encode(request), to: descriptor) else { throw ControlError.noReply }

        return try JSONDecoder().decode(ControlResponse.self, from: ControlSocket.readLine(from: descriptor, timeout: nil))
    }
}

enum ControlSocket {
    static func address(of path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ControlError.pathTooLong }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func readLine(from descriptor: Int32, timeout: TimeInterval?) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, timeout.map { Int32($0 * 1000) } ?? -1) > 0 else { throw ControlError.noReply }

            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else {
                guard !data.isEmpty else { throw ControlError.noReply }

                return data
            }

            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 0x0A) { return data.prefix(upTo: newline) }
            guard data.count <= ControlServer.maxRequest else { throw ControlError.requestTooLarge }
        }
    }

    static func writeLine(_ json: Data?, to descriptor: Int32) -> Bool {
        guard let json else { return false }

        let bytes = [UInt8](json) + [0x0A]
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }

            written += count
        }
        return true
    }
}
