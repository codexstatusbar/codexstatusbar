import Foundation
import Darwin

struct HelperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func systemCheck(_ success: Bool, _ operation: String) throws {
    guard success else { throw HelperError("\(operation) failed (errno \(errno))") }
}

// Walk with openat so a symlink cannot redirect private metadata writes.
func privateDirectory(_ path: String, createFrom: String) throws -> Int32 {
    guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
        throw HelperError("Absolute normalized directory required")
    }
    var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try systemCheck(fd >= 0, "open directory")
    do {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            let owned = current == createFrom || current.hasPrefix(createFrom + "/")
            if owned && mkdirat(fd, String(part), 0o700) != 0 && errno != EEXIST {
                throw HelperError("Cannot create private metadata directory")
            }
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try systemCheck(next >= 0, "open directory component")
            close(fd); fd = next
            if owned {
                var info = stat()
                try systemCheck(fstat(fd, &info) == 0, "stat private directory")
                guard info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
                    throw HelperError("Private directory must be owned by current user with mode 0700")
                }
            }
        }
        return fd
    } catch { close(fd); throw error }
}

func privateFile(in directory: Int32, name: String) throws -> Int32 {
    let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    try systemCheck(fd >= 0, "create private metadata file")
    return fd
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

func unixSocket(_ path: String, listen: Bool) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw HelperError("Unix socket path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try systemCheck(fd >= 0, "socket")
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    do {
        var one: Int32 = 1
        try systemCheck(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0, "socket options")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                listen ? Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) : Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try systemCheck(result == 0, listen ? "bind" : "connect")
        if listen {
            try systemCheck(chmod(path, 0o600) == 0, "socket mode")
            try systemCheck(Darwin.listen(fd, 1) == 0, "listen")
        } else { try sameUser(fd) }
        return fd
    } catch { close(fd); throw error }
}

func sameUser(_ fd: Int32) throws {
    var uid: uid_t = 0
    var gid: gid_t = 0
    try systemCheck(getpeereid(fd, &uid, &gid) == 0, "peer credentials")
    guard uid == getuid() else { throw HelperError("Unix peer UID mismatch") }
}

func processIdentity(_ pid: pid_t) throws -> [String: Any] {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
        throw HelperError("Cannot establish process start identity")
    }
    return ["pid": pid, "start_seconds": info.pbi_start_tvsec, "start_microseconds": info.pbi_start_tvusec]
}

// Shutdown and close share one lock so cancellation never touches a recycled FD.
final class RelayLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: Set<Int32> = []
    private var interrupted = false

    func add(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        descriptors.insert(fd)
        if interrupted { shutdown(fd, SHUT_RDWR) }
    }

    func closeSocket(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        descriptors.remove(fd)
        close(fd)
    }

    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        interrupted = true
        for fd in descriptors { shutdown(fd, SHUT_RDWR) }
    }
}
