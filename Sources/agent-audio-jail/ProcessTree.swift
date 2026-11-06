import Darwin
import Foundation

private let maximumAncestorDepth = 64

func readParentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var managementInfoBase: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&managementInfoBase, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

func readExecutableName(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
}

func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Walks up from `pid` and returns the nearest ancestor (or `pid` itself) whose
/// executable name is one of `agentNames`, so each agent session gets its own jail.
func findAgentRoot(of pid: pid_t, agentNames: Set<String>) -> pid_t? {
    var current = pid
    for _ in 0..<maximumAncestorDepth {
        guard current > 1 else { return nil }
        if let name = readExecutableName(of: current), agentNames.contains(name) {
            return current
        }
        guard let parent = readParentPID(of: current), parent != current else { return nil }
        current = parent
    }
    return nil
}

func readWorkingDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
