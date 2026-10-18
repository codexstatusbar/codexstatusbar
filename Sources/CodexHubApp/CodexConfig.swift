import Foundation
import Darwin
import CodexHubCore

/// Reads the default speed setting from the Codex home's configuration; nothing is written.
enum CodexConfig {
    /// A saved choice wins, otherwise the global `~/.codex`. The `CODEX_HOME` of the launching shell is ignored on
    /// purpose: it points at per-account or per-agent homes and would silently change what the app watches.
    static func defaultHome(saved: String?, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        saved ?? userHome.appendingPathComponent(".codex").path
    }

    static func configuredServiceTier(home: String) -> ServiceTier? {
        let path = URL(fileURLWithPath: home).appendingPathComponent("config.toml").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= 262_144 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        guard pread(fd, &bytes, bytes.count, 0) == bytes.count else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        return configuredServiceTier(in: text)
    }

    // Read only the simple home-level default; profiles/CLI overrides are not session evidence.
    static func configuredServiceTier(in text: String) -> ServiceTier? {
        var result: ServiceTier?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") { break }
            if line.contains("\"\"\"") || line.contains("'" + "''") { return nil }
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.first?.trimmingCharacters(in: .whitespaces) == "service_tier" else { continue }
            guard result == nil, pair.count == 2 else { return nil }
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote),
                  let tier = ServiceTier(rawValue: String(value[value.index(after: value.startIndex)..<end])) else { return nil }
            let rest = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
            result = tier
        }
        return result
    }
}
