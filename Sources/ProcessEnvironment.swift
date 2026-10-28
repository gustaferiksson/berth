import Darwin
import Foundation

enum ProcessEnvironment {
    static let tabKey = "BERTH_TAB"

    static func tabID(of pid: Int32) -> UUID? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size]
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        let prefix = "\(tabKey)="
        return strings.dropFirst(1 + Int(argc))
            .first { $0.hasPrefix(prefix) }
            .flatMap { UUID(uuidString: String($0.dropFirst(prefix.count))) }
    }
}
