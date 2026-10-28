import Darwin

enum ProcessAncestry {
    struct Process: Hashable {
        let pid: Int32
        let started: Int
    }

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

    static func descendants() -> Set<Process> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        let me = getpid()
        return Set(processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_proc.p_pid > 1 && $0.kp_proc.p_pid != me && isDescendant($0.kp_proc.p_pid, of: me) }
            .map { Process(pid: $0.kp_proc.p_pid, started: $0.kp_proc.p_starttime.tv_sec * 1_000_000 + Int($0.kp_proc.p_starttime.tv_usec)) })
    }

    static func hangUpDescendants() {
        hangUp(descendants())
    }

    static func hangUpOrphans(of before: Set<Process>) {
        let current = descendants()
        let orphans = before.filter { process in
            guard !current.contains(process) else { return false }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process.pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
            return info.kp_proc.p_starttime.tv_sec * 1_000_000 + Int(info.kp_proc.p_starttime.tv_usec) == process.started
        }
        hangUp(orphans)
    }

    private static func hangUp(_ processes: Set<Process>) {
        for signal in [SIGHUP, SIGTERM] {
            for process in processes { kill(process.pid, signal) }
        }
    }
}
