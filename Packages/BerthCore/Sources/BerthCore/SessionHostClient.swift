import Darwin
import Foundation

@_silgen_name("fork") private func rawFork() -> Int32

public final class HostConnection {
    private let descriptor: Int32
    private var decoder = HostFrameDecoder()

    public init(socketPath: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = try SessionHost.address(of: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw SessionHostError.connectFailed(code)
        }
    }

    deinit {
        close(descriptor)
    }

    public var fileDescriptor: Int32 { descriptor }

    @discardableResult
    public func send(_ frame: HostFrame) -> Bool {
        let bytes = frame.encoded()
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }

            written += count
        }
        return true
    }

    /// Waits up to `timeout` seconds for bytes. Nil once the host closed the connection.
    public func receive(timeout: TimeInterval) throws -> [HostFrame]? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR || errno == EAGAIN { return [] }
        guard count > 0 else { return nil }

        return try decoder.decode(Array(buffer.prefix(count)))
    }
}

public enum SessionHost {
    public static let ringCapacity = 256 * 1024

    public static func socketPath(directory: String, id: String) throws -> String {
        let path = directory + "/" + String(id.lowercased().filter(\.isHexDigit).prefix(12)) + ".sock"
        _ = try address(of: path)
        return path
    }

    static func address(of path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SessionHostError.pathTooLong }

        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = UInt8(bitPattern: byte) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    public static func probe(socketPath: String) -> (host: Int32, child: Int32)? {
        guard let connection = try? HostConnection(socketPath: socketPath), connection.send(.probe) else { return nil }

        let deadline = Date.now.addingTimeInterval(1)
        while Date.now < deadline {
            guard let frames = try? connection.receive(timeout: 0.1) else { return nil }

            for case let .hello(host, child) in frames { return (host, child) }
        }
        return nil
    }

    public static func hangUp(socketPath: String) {
        guard let connection = try? HostConnection(socketPath: socketPath) else { return }

        connection.send(.hangUp)
    }

    /// Reads what a fresh attach would show, then detaches without hanging anything up. Replaces the attached client.
    public static func scrollback(socketPath: String) -> [UInt8]? {
        guard let connection = try? HostConnection(socketPath: socketPath), connection.send(.attach(cols: 80, rows: 24)) else { return nil }

        var output: [UInt8] = []
        let deadline = Date.now.addingTimeInterval(1)
        while Date.now < deadline {
            guard let frames = try? connection.receive(timeout: 0.1) else { break }

            for case let .output(bytes) in frames { output += bytes }
        }
        return output
    }

    /// Detaches a host that outlives this process. Must run in a single-threaded process (the berth-host tool): it forks.
    public static func start(directory: String, id: String, command: String) throws {
        let path = try socketPath(directory: directory, id: id)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if probe(socketPath: path) != nil { return }

        unlink(path)
        let child = rawFork()
        if child == 0 {
            setsid()
            if rawFork() != 0 { _exit(0) }

            let null = open("/dev/null", O_RDWR)
            for descriptor: Int32 in 0...2 { dup2(null, descriptor) }
            _ = SessionHostServer.run(socketPath: path, command: command)
            _exit(0)
        }
        var status: Int32 = 0
        waitpid(child, &status, 0)
        for _ in 0..<250 {
            if probe(socketPath: path) != nil { return }

            usleep(20000)
        }
        throw SessionHostError.startTimedOut
    }

    /// Relays the terminal to the host until the host's child exits; returns that child's status.
    public static func attach(socketPath: String) -> Int32 {
        guard let connection = try? HostConnection(socketPath: socketPath) else {
            FileHandle.standardError.write(Data("berth-host: no session host at \(socketPath)\n".utf8))
            return 1
        }

        var original = termios()
        let isTerminal = tcgetattr(STDIN_FILENO, &original) == 0
        if isTerminal {
            var raw = original
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if isTerminal { tcsetattr(STDIN_FILENO, TCSANOW, &original) } }

        var size = windowSize()
        connection.send(.attach(cols: size.ws_col, rows: size.ws_row))
        var poller = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: connection.fileDescriptor, events: Int16(POLLIN), revents: 0)]
        var input = [UInt8](repeating: 0, count: 8192)
        while true {
            poll(&poller, 2, 250)
            let current = windowSize()
            if current.ws_col != size.ws_col || current.ws_row != size.ws_row {
                size = current
                connection.send(.resize(cols: size.ws_col, rows: size.ws_row))
            }
            if poller[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = input.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count > 0 {
                    connection.send(.input(Array(input.prefix(count))))
                } else if count == 0 || errno != EINTR && errno != EAGAIN {
                    return 0
                }
            }
            guard poller[1].revents != 0 else { continue }

            guard let frames = try? connection.receive(timeout: 0) else { return 1 }

            for frame in frames {
                switch frame {
                case let .output(bytes): writeAll(STDOUT_FILENO, bytes)
                case let .exit(status): return status
                case .replaced: return 0
                default: break
                }
            }
        }
    }

    private static func windowSize() -> winsize {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_col == 0 { return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }

        return size
    }

    private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
        var written = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return }

            written += count
        }
    }
}
