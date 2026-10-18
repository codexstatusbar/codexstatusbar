import Foundation
import Darwin
import CSQLite

final class MetadataStore: @unchecked Sendable {
    private let directory: SafeDirectory
    private var db: OpaquePointer?
    private let lockFD: Int32
    private var databaseIdentity: (dev_t, ino_t)?

    init(directoryURL: URL, sourceScope: String) throws {
        directory = try SafeDirectory(directoryURL, createPrivate: true)
        lockFD = dup(directory.fd)
        guard lockFD >= 0 else { throw CollectorError.database }
        guard Self.lock(lockFD) else {
            close(lockFD)
            throw CollectorError.metadataInUse
        }
        do {
            try directory.validateMetadataFiles()
            let created = openat(directory.fd, "metadata.sqlite", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard created >= 0 else { throw CollectorError.unsafePath }
            var identity = stat()
            guard fstat(created, &identity) == 0 else { close(created); throw CollectorError.unsafePath }
            databaseIdentity = (identity.st_dev, identity.st_ino)
            close(created)
            guard let canonical = realpath(directory.url.path, nil) else { throw CollectorError.unsafePath }
            defer { free(canonical) }
            let path = String(cString: canonical) + "/metadata.sqlite"
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else { throw CollectorError.database }
            sqlite3_busy_timeout(db, 1000)
            let applicationID = try scalar("PRAGMA application_id")
            guard try applicationID == 1128813890 || (applicationID == 0 && scalar("SELECT count(*) FROM sqlite_master") == 0) else {
                throw CollectorError.database
            }
            try execute("PRAGMA application_id=1128813890")
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS files(identity TEXT PRIMARY KEY, state BLOB NOT NULL, updated REAL NOT NULL); CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1), days INTEGER NOT NULL, row_limit INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS source(home TEXT NOT NULL); CREATE TABLE IF NOT EXISTS chart_history(id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);")
            let existing = try prepare("SELECT home FROM source")
            defer { sqlite3_finalize(existing) }
            let result = sqlite3_step(existing)
            if result == SQLITE_ROW {
                guard let scope = sqlite3_column_text(existing, 0), String(cString: scope) == sourceScope else { throw CollectorError.sourceMismatch }
            } else if result == SQLITE_DONE {
                let insert = try prepare("INSERT INTO source(home) VALUES(?)")
                defer { sqlite3_finalize(insert) }
                sqlite3_bind_text(insert, 1, sourceScope, -1, transient)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw CollectorError.database }
            } else { throw CollectorError.database }
        } catch {
            sqlite3_close(db)
            close(lockFD)
            throw error
        }
    }
    deinit { sqlite3_close(db); close(lockFD) }

    /// An actor is not released synchronously with its last reference, so a collector restarted on the same
    /// directory can meet the previous lock for a moment; wait briefly before treating it as held elsewhere.
    private static func lock(_ fd: Int32) -> Bool {
        for _ in 0..<50 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK else { return false }
            usleep(20_000)
        }
        return false
    }

    private func validate() throws {
        try directory.validateMetadataFiles()
        var current = stat()
        guard fstatat(directory.fd, "metadata.sqlite", &current, AT_SYMLINK_NOFOLLOW) == 0,
              let identity = databaseIdentity, current.st_dev == identity.0, current.st_ino == identity.1 else { throw CollectorError.unsafePath }
    }

    private func scalar(_ sql: String) throws -> Int32 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CollectorError.database }
        return sqlite3_column_int(statement, 0)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CollectorError.database }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CollectorError.database }
        return statement
    }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func load() throws -> [String: FileState] {
        try validate()
        let statement = try prepare("SELECT identity,state FROM files")
        defer { sqlite3_finalize(statement) }
        var result: [String: FileState] = [:]
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard result.count < 10_000 else { throw CollectorError.database }
            guard let id = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) else { throw CollectorError.database }
            let size = Int(sqlite3_column_bytes(statement, 1))
            guard size <= 16_384 else { throw CollectorError.database }
            guard let state = try? JSONDecoder().decode(FileState.self, from: Data(bytes: bytes, count: size)) else { throw CollectorError.database }
            guard state.offset >= 0, state.historicalUntil >= 0,
                  state.path.utf8.count <= 4096, state.updated.isFinite else { throw CollectorError.database }
            result[String(cString: id)] = state
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw CollectorError.database }
        return result
    }

    func loadChartHistory() throws -> Data? {
        try validate()
        let statement = try prepare("SELECT payload FROM chart_history WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw CollectorError.database }
        let size = Int(sqlite3_column_bytes(statement, 0))
        guard (1...4_194_304).contains(size) else { throw CollectorError.database }
        return Data(bytes: bytes, count: size)
    }

    func saveChartHistory(_ data: Data) throws {
        try validate()
        guard !data.isEmpty, data.count <= 4_194_304 else { throw CollectorError.database }
        let statement = try prepare("INSERT OR REPLACE INTO chart_history(id,payload) VALUES(1,?)")
        defer { sqlite3_finalize(statement) }
        let code = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), transient) }
        guard code == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw CollectorError.database }
    }

    func retention() throws -> RetentionPolicy {
        let statement = try prepare("SELECT days,row_limit FROM settings WHERE id=1")
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return try RetentionPolicy() }
        guard code == SQLITE_ROW else { throw CollectorError.database }
        return try RetentionPolicy(days: Int(sqlite3_column_int(statement, 0)), maximumSessions: Int(sqlite3_column_int(statement, 1)))
    }

    func save(_ states: [String: FileState], retention: RetentionPolicy, clearChartHistory: Bool = false) throws {
        try validate()
        try execute("BEGIN IMMEDIATE")
        do {
            if clearChartHistory { try execute("DELETE FROM chart_history") }
            try execute("DELETE FROM files")
            let statement = try prepare("INSERT INTO files(identity,state,updated) VALUES(?,?,?)")
            defer { sqlite3_finalize(statement) }
            for (id, state) in states {
                let data = try JSONEncoder().encode(state)
                sqlite3_bind_text(statement, 1, id, -1, transient)
                let code = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
                guard code == SQLITE_OK else { throw CollectorError.database }
                sqlite3_bind_double(statement, 3, state.updated)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw CollectorError.database }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            let settings = try prepare("INSERT OR REPLACE INTO settings(id,days,row_limit) VALUES(1,?,?)")
            defer { sqlite3_finalize(settings) }
            sqlite3_bind_int(settings, 1, Int32(retention.days))
            sqlite3_bind_int(settings, 2, Int32(retention.maximumSessions))
            guard sqlite3_step(settings) == SQLITE_DONE else { throw CollectorError.database }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw CollectorError.database
        }
    }
}
