import Foundation
import Darwin
import CSQLite

/// Reads when a response stream began from Codex's own tracing log (`logs_2.sqlite`, read-only).
/// The response headers arrive when generation starts, so time before them is request latency, not output.
final class StreamStartLog: @unchecked Sendable {
    private let path: String
    private var db: OpaquePointer?

    init(codexHome: URL) {
        path = codexHome.resolvingSymlinksInPath().appendingPathComponent("logs_2.sqlite").path
    }

    deinit { sqlite3_close(db) }

    /// Latest sampling-request header time for `thread` within `[earliest, latest]`, or nil when it cannot be established.
    func streamStart(thread: String, earliest: Double, latest: Double) -> Double? {
        guard earliest.isFinite, latest.isFinite, latest > earliest, thread.utf8.count <= 256, open() else { return nil }
        let sql = """
        SELECT ts, ts_nanos FROM logs WHERE thread_id = ?1 AND ts >= ?2 AND ts <= ?3
        AND target = 'codex_http_client::client' AND feedback_log_body LIKE '%try_run_sampling_request%'
        AND feedback_log_body LIKE '%version=HTTP/1.1' ORDER BY id DESC LIMIT 8
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, thread, -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(earliest.rounded(.down)))
        sqlite3_bind_int64(statement, 3, Int64(latest.rounded(.up)))
        while sqlite3_step(statement) == SQLITE_ROW {
            let time = Double(sqlite3_column_int64(statement, 0)) + Double(sqlite3_column_int64(statement, 1)) / 1_000_000_000
            if time >= earliest, time <= latest { return time }
        }
        return nil
    }

    private func open() -> Bool {
        if db != nil { return true }
        var handle: OpaquePointer?
        // SQLite's no-follow mode rejects any symlinked path component, so open the canonical path.
        guard let canonical = realpath(path, nil) else { return false }
        defer { free(canonical) }
        guard sqlite3_open_v2(canonical, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        sqlite3_busy_timeout(handle, 100)
        db = handle
        return true
    }
}
