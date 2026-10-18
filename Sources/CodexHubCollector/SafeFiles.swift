import Foundation
import Darwin

public enum CollectorError: Error, Equatable, Sendable {
    case unsafePath, inaccessibleSource, database, invalidSettings, invalidRecord, oversizedRecord, sourceMismatch, ambiguousSource

    public var message: String {
        switch self {
        case .ambiguousSource: "Multiple source files claim the same session; measurement is partial."
        case .unsafePath: "A file path, owner, type, or permission is unsafe."
        case .inaccessibleSource: "The selected session logs could not be read."
        case .database: "Hub metadata could not be read or saved."
        case .invalidSettings: "The retention settings or clock value is invalid."
        case .invalidRecord: "A log record or session identity could not be safely interpreted."
        case .oversizedRecord: "A source exceeded the collector size or traversal limit."
        case .sourceMismatch: "This metadata directory belongs to another Codex home; use a separate directory."
        }
    }
}

final class SafeDirectory: @unchecked Sendable {
    let fd: Int32
    let url: URL
    private let requirePrivate: Bool

    init(_ url: URL, createPrivate: Bool = false, requirePrivate: Bool = false) throws {
        self.url = url.standardizedFileURL
        self.requirePrivate = createPrivate || requirePrivate
        if createPrivate {
            guard mkdir(self.url.path, 0o700) == 0 || errno == EEXIST else { throw CollectorError.unsafePath }
        }
        fd = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CollectorError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              !self.requirePrivate || info.st_mode & 0o077 == 0 else {
            close(fd)
            throw CollectorError.unsafePath
        }
    }
    deinit { close(fd) }

    // Read-only source logs may be hardlinked; writable private metadata must have one link.
    func openFile(_ relative: String) throws -> Int32 {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CollectorError.unsafePath }
        var parent = dup(fd)
        guard parent >= 0 else { throw CollectorError.inaccessibleSource }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw CollectorError.unsafePath }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == getuid(), !requirePrivate || info.st_mode & 0o077 == 0 else { close(next); throw CollectorError.unsafePath }
            close(parent)
            parent = next
        }
        let file = openat(parent, String(parts.last!), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw CollectorError.unsafePath }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              !requirePrivate || (info.st_nlink == 1 && info.st_mode & 0o077 == 0) else {
            close(file)
            throw CollectorError.unsafePath
        }
        return file
    }

    func logPaths(subdirectory: String = "sessions") throws -> (paths: [String], rejected: Bool) {
        let sessions = subdirectory.isEmpty ? dup(fd) : openat(fd, subdirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sessions >= 0 else { throw CollectorError.inaccessibleSource }
        defer { close(sessions) }
        var paths: [String] = []
        var rejected = false
        var entries = 0
        func walk(_ parent: Int32, prefix: String, depth: Int) throws {
            var owner = stat()
            guard fstat(parent, &owner) == 0, owner.st_uid == getuid(), !requirePrivate || owner.st_mode & 0o077 == 0 else { throw CollectorError.unsafePath }
            guard depth <= 16, let directory = fdopendir(dup(parent)) else { throw CollectorError.oversizedRecord }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                entries += 1
                guard entries <= 20_000 else { throw CollectorError.oversizedRecord }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { rejected = true; continue }
                if info.st_uid != getuid() || info.st_mode & S_IFMT == S_IFLNK || (requirePrivate && info.st_mode & 0o077 != 0) { rejected = true; continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { rejected = true; continue }
                    defer { close(child) }
                    do { try walk(child, prefix: path, depth: depth + 1) } catch { rejected = true }
                } else if name.hasSuffix(".jsonl") { paths.append(path) }
            }
        }
        try walk(sessions, prefix: subdirectory, depth: 0)
        return (paths.sorted(), rejected)
    }

    func validateMetadataFiles() throws {
        var root = stat()
        var named = stat()
        guard lstat(url.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
              fstat(fd, &root) == 0, named.st_dev == root.st_dev, named.st_ino == root.st_ino,
              fstat(fd, &root) == 0, root.st_uid == getuid(), root.st_mode & 0o077 == 0 else { throw CollectorError.unsafePath }
        for name in ["metadata.sqlite", "metadata.sqlite-journal", "metadata.sqlite-wal", "metadata.sqlite-shm"] {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw CollectorError.unsafePath }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw CollectorError.unsafePath }
        }
    }
}
