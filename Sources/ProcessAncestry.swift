import BerthCore
import Darwin
import Foundation

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

    private nonisolated static func userProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }

        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }

        return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    static func descendants() -> Set<Process> {
        let ownPID = getpid()
        return Set(userProcesses()
            .filter { $0.kp_proc.p_pid > 1 && $0.kp_proc.p_pid != ownPID && isDescendant($0.kp_proc.p_pid, of: ownPID) }
            .map { Process(pid: $0.kp_proc.p_pid, started: $0.kp_proc.p_starttime.tv_sec * 1_000_000 + Int($0.kp_proc.p_starttime.tv_usec)) })
    }

    nonisolated static func terminalTasks(for rollout: URL, under root: Int32, named name: String, excluding excluded: Set<String>) -> [RemoteTask] {
        var file = stat()
        guard stat(rollout.path, &file) == 0 else { return [] }

        let processes = userProcesses()
        let owners = processes.filter { process in
            let pid = process.kp_proc.p_pid
            let shortName = withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return shortName == name && (pid == root || isDescendant(pid, of: root)) && holds(file, pid: pid)
        }
        guard owners.count == 1, let owner = owners.first?.kp_proc.p_pid else { return [] }

        return processes.compactMap { process -> RemoteTask? in
            guard process.kp_eproc.e_ppid == owner, Int32(process.kp_proc.p_stat) != SZOMB else { return nil }

            let pid = process.kp_proc.p_pid
            var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            let executable = if length > 0 {
                URL(filePath: String(decoding: path.prefix(Int(length)).prefix { $0 != 0 }, as: UTF8.self)).lastPathComponent
            } else {
                withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            }
            guard !executable.isEmpty, !excluded.contains(where: { length > 0 ? $0 == executable : $0.hasPrefix(executable) }) else { return nil }

            let start = process.kp_proc.p_starttime
            let started = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
            let command = commandLine(of: pid) ?? executable
            return RemoteTask(id: "shell-\(pid)-\(start.tv_sec)-\(start.tv_usec)", kind: RemoteTask.shell, title: command, started: started, command: command)
        }.sorted { $0.started < $1.started }
    }

    private nonisolated static func holds(_ file: stat, pid: Int32) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }

        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &entries, size)
        return entries.prefix(max(Int(read), 0) / MemoryLayout<proc_fdinfo>.stride).contains { entry in
            guard entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return false }

            var vnode = vnode_fdinfowithpath()
            let bytes = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, bytes) == bytes else { return false }

            let stat = vnode.pvip.vip_vi.vi_stat
            return stat.vst_ino == file.st_ino && stat.vst_dev == UInt32(bitPattern: file.st_dev)
        }
    }

    private nonisolated static func commandLine(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        let body = data.prefix(size).dropFirst(MemoryLayout<Int32>.size)
        guard count > 0, let terminator = body.firstIndex(of: 0) else { return nil }

        let arguments = body.dropFirst(terminator - body.startIndex + 1).drop(while: { $0 == 0 })
        let command = arguments.split(separator: 0, maxSplits: Int(count), omittingEmptySubsequences: false)
            .prefix(Int(count)).map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
        return command.isEmpty ? nil : command
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
