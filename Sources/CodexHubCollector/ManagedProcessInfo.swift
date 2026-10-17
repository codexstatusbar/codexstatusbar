import Foundation
import Darwin
import CodexHubCore

public struct ManagedProcessInfo: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case tui, appServer = "app_server", relay }
    public let role: Role
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, osStartTime: "\(startSeconds).\(String(format: "%06llu", startMicroseconds))")
    }

    var connectivity: Connectivity {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return errno == ESRCH ? .disconnected : .unknown
        }
        return info.pbi_start_tvsec == startSeconds && info.pbi_start_tvusec == startMicroseconds ? .connected : .disconnected
    }
}
