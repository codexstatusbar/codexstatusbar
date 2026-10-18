import Foundation
import Darwin
import CodexHubCore

/// Reads the default speed setting from the Codex home's configuration; nothing is written.
enum CodexConfig {
    /// A saved choice wins. Otherwise the home most running terminal Codex processes use (a process without
    /// `CODEX_HOME` uses the global `~/.codex`), and `~/.codex` when none runs. The launching shell's own
    /// `CODEX_HOME` is ignored on purpose: it would silently change what the app watches.
    static func defaultHome(saved: String?, running: [String?] = [], userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let saved { return saved }
        let global = userHome.appendingPathComponent(".codex").path
        let counts = Dictionary(grouping: running.map { $0 ?? global }, by: { $0 }).mapValues(\.count)
        // Most processes win; a tie goes to the global home, then to the path that sorts first.
        let best = counts.max { left, right in
            if left.value != right.value { return left.value < right.value }
            if (left.key == global) != (right.key == global) { return right.key == global }
            return left.key > right.key
        }
        return best?.key ?? global
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
