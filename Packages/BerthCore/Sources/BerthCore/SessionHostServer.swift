import Darwin
import Foundation

@_silgen_name("forkpty") private func rawForkpty(_ master: UnsafeMutablePointer<Int32>, _ name: UnsafeMutablePointer<CChar>?, _ term: UnsafePointer<termios>?, _ window: UnsafePointer<winsize>?) -> Int32

nonisolated(unsafe) private var terminationRequested: sig_atomic_t = 0

public enum SessionHostServer {
    private final class Client {
        let descriptor: Int32
        var decoder = HostFrameDecoder()
        var outbox: [UInt8] = []
        var isAttached = false
        var closesWhenFlushed = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }
    }

    private enum HangUp {
        case none
        case since(Date)
    }

    /// Owns one pty and its child until the child exits. Single-threaded poll loop; returns the child's status.
    public static func run(socketPath: String, command: String) -> Int32 {
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in terminationRequested = 1 }
        guard let listener = listen(on: socketPath) else { return 1 }

        var master: Int32 = 0
        var window = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let arguments = ["sh", "-c", command].map { strdup($0) } + [nil]
        let child = rawForkpty(&master, nil, nil, &window)
        if child == 0 {
            signal(SIGHUP, SIG_DFL)
            signal(SIGPIPE, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
            execv("/bin/sh", arguments)
            _exit(127)
        }
        guard child > 0 else { return 1 }

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        var ring = ScrollbackRing(capacity: SessionHost.ringCapacity)
        var clients: [Client] = []
        var pendingInput: [UInt8] = []
        var hangUp = HangUp.none
        var status: Int32?
        var buffer = [UInt8](repeating: 0, count: 65536)

        func readMaster() -> Bool {
            let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            guard count > 0 else { return count < 0 && (errno == EAGAIN || errno == EINTR) }

            let bytes = Array(buffer.prefix(count))
            ring.append(bytes)
            clients.first { $0.isAttached }?.outbox += HostFrame.output(bytes).encoded()
            return true
        }

        func setWindow(cols: UInt16, rows: UInt16) {
            var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, TIOCSWINSZ, &size)
        }

        func handle(_ frame: HostFrame, from client: Client) {
            switch frame {
            case let .attach(cols, rows):
                for other in clients where other.isAttached && other !== client {
                    other.outbox += HostFrame.replaced.encoded()
                    other.isAttached = false
                    other.closesWhenFlushed = true
                }
                client.isAttached = true
                client.outbox += HostFrame.hello(host: getpid(), child: child).encoded()
                let replay = ring.contents
                for start in stride(from: 0, to: replay.count, by: 32768) {
                    client.outbox += HostFrame.output(Array(replay[start..<min(start + 32768, replay.count)])).encoded()
                }
                setWindow(cols: cols, rows: rows + 1)
                usleep(20000)
                setWindow(cols: cols, rows: rows)
            case let .input(bytes) where client.isAttached:
                pendingInput += bytes
            case let .resize(cols, rows) where client.isAttached:
                setWindow(cols: cols, rows: rows)
            case .hangUp:
                if case .none = hangUp { hangUp = .since(.now) }
            case .probe:
                client.outbox += HostFrame.hello(host: getpid(), child: child).encoded()
                client.closesWhenFlushed = true
            default:
                break
            }
        }

        while true {
            if terminationRequested != 0, case .none = hangUp { hangUp = .since(.now) }
            if status == nil {
                var raw: Int32 = 0
                if waitpid(child, &raw, WNOHANG) == child { status = raw & 0x7F == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F) }
            }
            if let status {
                while readMaster() {}
                finish(status: status, clients: clients, socketPath: socketPath)
                return status
            }
            if case let .since(start) = hangUp {
                let elapsed = Date.now.timeIntervalSince(start)
                let signalNumber = elapsed < 1 ? SIGHUP : elapsed < 3 ? SIGTERM : SIGKILL
                let foreground = tcgetpgrp(master)
                if foreground > 0 { killpg(foreground, signalNumber) }
                killpg(child, signalNumber)
            }

            clients.removeAll { client in
                guard client.closesWhenFlushed, client.outbox.isEmpty else { return false }

                close(client.descriptor)
                return true
            }
            var descriptors = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: master, events: Int16(POLLIN) | (pendingInput.isEmpty ? 0 : Int16(POLLOUT)), revents: 0)]
            descriptors += clients.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN) | ($0.outbox.isEmpty ? 0 : Int16(POLLOUT)), revents: 0) }
            guard poll(&descriptors, nfds_t(descriptors.count), 100) >= 0 || errno == EINTR else { continue }

            if descriptors[0].revents & Int16(POLLIN) != 0 {
                let accepted = accept(listener, nil, nil)
                if accepted >= 0, clients.count < 8 {
                    _ = fcntl(accepted, F_SETFL, fcntl(accepted, F_GETFL) | O_NONBLOCK)
                    var enabled: Int32 = 1
                    setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                    clients.append(Client(descriptor: accepted))
                } else if accepted >= 0 {
                    close(accepted)
                }
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 { _ = readMaster() }
            if descriptors[1].revents & Int16(POLLOUT) != 0, !pendingInput.isEmpty {
                let count = pendingInput.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
                if count > 0 { pendingInput.removeFirst(count) }
            }
            for (index, polled) in descriptors.dropFirst(2).enumerated() {
                let client = clients[index]
                guard polled.revents != 0 else { continue }

                if polled.revents & Int16(POLLOUT) != 0, !client.outbox.isEmpty {
                    let count = client.outbox.withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }
                    if count > 0 { client.outbox.removeFirst(count) }
                }
                guard polled.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }

                let count = buffer.withUnsafeMutableBytes { read(client.descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EAGAIN || errno == EINTR { continue }

                let frames = count > 0 ? try? client.decoder.decode(Array(buffer.prefix(count))) : nil
                guard let frames else {
                    client.isAttached = false
                    client.outbox = []
                    client.closesWhenFlushed = true
                    continue
                }

                for frame in frames { handle(frame, from: client) }
            }
            if pendingInput.count > 1 << 20 { pendingInput = [] }
        }
    }

    private static func listen(on path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = try? SessionHost.address(of: path) else { return nil }

        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else { return nil }

        return descriptor
    }

    private static func finish(status: Int32, clients: [Client], socketPath: String) {
        unlink(socketPath)
        for client in clients where client.isAttached {
            let frame = HostFrame.exit(status).encoded()
            client.outbox += frame
            for _ in 0..<20 where !client.outbox.isEmpty {
                var poller = pollfd(fd: client.descriptor, events: Int16(POLLOUT), revents: 0)
                guard poll(&poller, 1, 50) > 0 else { continue }

                let count = client.outbox.withUnsafeBytes { write(client.descriptor, $0.baseAddress, $0.count) }
                if count > 0 { client.outbox.removeFirst(count) }
            }
        }
    }
}
