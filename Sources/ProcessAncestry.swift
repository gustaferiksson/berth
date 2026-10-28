import Darwin

enum ProcessAncestry {
    static func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
        var current = pid
        for _ in 0..<16 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            let parent = info.kp_eproc.e_ppid
            if parent == ancestor { return true }
            guard parent > 1 else { return false }
            current = parent
        }
        return false
    }

    static func hangUpDescendants() {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return }
        let me = getpid()
        let descendants = processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map(\.kp_proc.p_pid)
            .filter { $0 > 1 && $0 != me && isDescendant($0, of: me) }
        for signal in [SIGHUP, SIGTERM] {
            for pid in descendants { kill(pid, signal) }
        }
    }
}
