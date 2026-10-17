import Foundation
import Darwin
import CodexHubCore

struct RunningCodexProcess: Sendable {
    let identity: ProcessIdentity
    let writableFileIDs: Set<String>
    /// `codex app-server` hosts (for example inside the ChatGPT app) are backends, not terminal sessions.
    /// One that owns no transcript has no session to attach, so it must not be listed as a missing one.
    var isAppServer = false

    static func capture() -> [Self]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count <= 16_384 else { return nil }
        var pids = [pid_t](repeating: 0, count: min(Int(count) + 128, 16_384))
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.stride)
        let copied = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bytes) }
        guard copied > 0, copied <= pids.count else { return nil }
        return pids.prefix(Int(copied)).compactMap(inspect).sorted { $0.identity.pid < $1.identity.pid }
    }

    static func inspect(_ pid: pid_t) -> Self? {
        guard pid > 0 else { return nil }
        var before = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, infoSize) == infoSize,
              before.pbi_uid == getuid(), before.pbi_status != SZOMB else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0, URL(fileURLWithPath: String(cString: path)).lastPathComponent == "codex" else { return nil }
        let appServer = arguments(of: pid)?.dropFirst().contains("app-server") == true
        var files: Set<String> = []
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        if needed > 0, needed <= 4096 * stride {
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: min(Int(needed) / stride + 32, 4096))
            let size = Int32(descriptors.count * stride)
            let copied = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size) }
            if copied > 0, copied <= size {
                for descriptor in descriptors.prefix(Int(copied) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
                    var vnode = vnode_fdinfo()
                    let vnodeSize = Int32(MemoryLayout<vnode_fdinfo>.size)
                    guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEINFO, &vnode, vnodeSize) == vnodeSize,
                          vnode.pfi.fi_openflags & UInt32(FWRITE) != 0,
                          vnode.pvi.vi_stat.vst_mode & S_IFMT == S_IFREG else { continue }
                    let file = vnode.pvi.vi_stat
                    files.insert("\(Int32(bitPattern: file.vst_dev)):\(file.vst_ino)")
                }
            }
        }
        var after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, infoSize) == infoSize,
              after.pbi_uid == before.pbi_uid, after.pbi_status != SZOMB,
              after.pbi_start_tvsec == before.pbi_start_tvsec,
              after.pbi_start_tvusec == before.pbi_start_tvusec else { return nil }
        return Self(identity: ProcessIdentity(pid: pid, osStartTime: "\(before.pbi_start_tvsec).\(String(format: "%06llu", before.pbi_start_tvusec))"), writableFileIDs: files, isAppServer: appServer)
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1 << 20 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var result: [String] = []
        while result.count < count, index < size {
            var end = index
            while end < size, buffer[end] != 0 { end += 1 }
            result.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return result
    }

    static func owner(of fileID: String, controller: ProcessIdentity?, in processes: [Self]) -> ProcessIdentity? {
        let matches = processes.filter { $0.writableFileIDs.contains(fileID) || $0.identity == controller }
        return matches.count == 1 ? matches[0].identity : nil
    }
}
