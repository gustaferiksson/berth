public enum SessionHostError: Error, Equatable {
    case pathTooLong
    case connectFailed(Int32)
    case malformedFrame
    case unsupportedVersion(UInt8)
    case startTimedOut
}

public enum HostFrame: Equatable, Sendable {
    case attach(cols: UInt16, rows: UInt16)
    case input([UInt8])
    case resize(cols: UInt16, rows: UInt16)
    case hangUp
    case probe
    case output([UInt8])
    case exit(Int32)
    case replaced
    case hello(host: Int32, child: Int32)

    public static let version: UInt8 = 1
    public static let maxPayload = 1 << 20

    private enum Kind: UInt8 {
        case attach = 0x01, input, resize, hangUp, probe
        case output = 0x81, exit, replaced, hello
    }

    public func encoded() -> [UInt8] {
        let (kind, payload): (Kind, [UInt8]) = switch self {
        case let .attach(cols, rows): (.attach, [Self.version] + Self.bytes(cols) + Self.bytes(rows))
        case let .input(bytes): (.input, bytes)
        case let .resize(cols, rows): (.resize, Self.bytes(cols) + Self.bytes(rows))
        case .hangUp: (.hangUp, [])
        case .probe: (.probe, [])
        case let .output(bytes): (.output, bytes)
        case let .exit(status): (.exit, Self.bytes(UInt32(bitPattern: status)))
        case .replaced: (.replaced, [])
        case let .hello(host, child): (.hello, Self.bytes(UInt32(bitPattern: host)) + Self.bytes(UInt32(bitPattern: child)))
        }
        return [kind.rawValue] + Self.bytes(UInt32(payload.count)) + payload
    }

    fileprivate static func decode(kind: UInt8, payload: [UInt8]) throws -> Self {
        guard let kind = Kind(rawValue: kind) else { throw SessionHostError.malformedFrame }

        switch kind {
        case .attach:
            guard payload.count == 5 else { throw SessionHostError.malformedFrame }
            guard payload[0] == version else { throw SessionHostError.unsupportedVersion(payload[0]) }

            return .attach(cols: UInt16(truncatingIfNeeded: integer(payload[1..<3])), rows: UInt16(truncatingIfNeeded: integer(payload[3..<5])))
        case .input: return .input(payload)
        case .resize:
            guard payload.count == 4 else { throw SessionHostError.malformedFrame }

            return .resize(cols: UInt16(truncatingIfNeeded: integer(payload[0..<2])), rows: UInt16(truncatingIfNeeded: integer(payload[2..<4])))
        case .hangUp: return .hangUp
        case .probe: return .probe
        case .output: return .output(payload)
        case .exit:
            guard payload.count == 4 else { throw SessionHostError.malformedFrame }

            return .exit(Int32(bitPattern: UInt32(truncatingIfNeeded: integer(payload[0..<4]))))
        case .replaced: return .replaced
        case .hello:
            guard payload.count == 8 else { throw SessionHostError.malformedFrame }

            return .hello(host: Int32(bitPattern: UInt32(truncatingIfNeeded: integer(payload[0..<4]))), child: Int32(bitPattern: UInt32(truncatingIfNeeded: integer(payload[4..<8]))))
        }
    }

    private static func bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> UInt32(24 - 8 * $0)) & 0xFF) }
    }

    fileprivate static func integer(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }
}

public struct HostFrameDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func decode(_ bytes: [UInt8]) throws -> [HostFrame] {
        buffer += bytes
        var frames: [HostFrame] = []
        var offset = 0
        while buffer.count - offset >= 5 {
            let length = Int(HostFrame.integer(buffer[(offset + 1)..<(offset + 5)]))
            guard length <= HostFrame.maxPayload else { throw SessionHostError.malformedFrame }
            guard buffer.count - offset >= 5 + length else { break }

            frames.append(try HostFrame.decode(kind: buffer[offset], payload: Array(buffer[(offset + 5)..<(offset + 5 + length)])))
            offset += 5 + length
        }
        buffer.removeFirst(offset)
        return frames
    }
}

public struct ScrollbackRing {
    public let capacity: Int
    private var storage: [UInt8] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public var contents: [UInt8] {
        Array(storage.suffix(capacity))
    }

    public mutating func append(_ bytes: [UInt8]) {
        storage += bytes
        if storage.count > capacity * 2 { storage = Array(storage.suffix(capacity)) }
    }
}
