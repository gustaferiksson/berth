import BerthCore
import Darwin

enum ProcessAncestry {
    struct Process: Hashable {
        let pid: Int32
        let started: Int
    }

    nonisolated static func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
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

        let ownPID = getpid()
        return Set(processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .filter { $0.kp_proc.p_pid > 1 && $0.kp_proc.p_pid != ownPID && isDescendant($0.kp_proc.p_pid, of: ownPID) }
            .map { Process(pid: $0.kp_proc.p_pid, started: $0.kp_proc.p_starttime.tv_sec * 1_000_000 + Int($0.kp_proc.p_starttime.tv_usec)) })
    }

    nonisolated static func listeningPorts(under root: Int32) -> [Int] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: Int(capacity) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        let ports = pids.prefix(max(Int(filled), 0)).filter { $0 > 1 && ($0 == root || isDescendant($0, of: root)) }.flatMap { pid in
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { return [Int]() }

            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
            let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bytes)
            return descriptors.prefix(max(Int(read), 0) / MemoryLayout<proc_fdinfo>.stride).compactMap { descriptor in
                guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }

                var socket = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                      socket.psi.soi_kind == SOCKINFO_TCP,
                      socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { return nil }

                return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            }
        }
        return Array(Set(ports)).sorted()
    }

    static func hangUpDescendants() {
        let processes = descendants()
        hangUp(processes)
        for _ in 0..<20 where processes.contains(where: { isRunning($0.pid) }) { Darwin.usleep(50_000) }
        for process in processes where isRunning(process.pid) { kill(process.pid, SIGKILL) }
    }

    static func facts(of pid: Int32) -> OrphanedSessions.Process? {
        guard let info = info(of: pid) else { return nil }

        return OrphanedSessions.Process(parent: info.kp_eproc.e_ppid, hasTerminal: info.kp_eproc.e_tdev != -1)
    }

    static func end(_ pid: Int32) async -> Bool {
        for signal in [SIGHUP, SIGTERM, SIGKILL] {
            kill(pid, signal)
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if !isRunning(pid) { return true }
            }
        }
        return !isRunning(pid)
    }

    private static func isRunning(_ pid: Int32) -> Bool {
        guard let info = info(of: pid) else { return false }

        return Int32(info.kp_proc.p_stat) != SZOMB
    }

    private static func info(of pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }

        return info
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
