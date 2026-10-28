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
}
