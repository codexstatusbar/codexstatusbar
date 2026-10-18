import Foundation
import Darwin
import CryptoKit
import CodexHubCore

enum HelperConnection {
    static var bundledURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/codex-hub") }

    static func executable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return false }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func discoverCodex() -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }.first(where: executable)
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func command(home: String, codex: String, helper: String) -> String {
        "env CODEX_HOME=" + shellQuote(home) + " " + shellQuote(helper) + " run --experimental --codex " + shellQuote(codex)
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

    // User-triggered only; arbitrary subprocess output is discarded, never shown or persisted.
    static func doctor(home: String, codex: String, helper: String) -> String {
        guard executable(helper), executable(codex) else { return "Helper or Codex executable is unavailable. Choose the installed Codex executable." }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["doctor", "--codex", codex]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "Doctor could not start. Check executable permissions." }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            return "Doctor timed out. Managed compatibility remains unverified."
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
            ? "Installed Codex matches the helper's supported version. Relay behavior and G0 remain unverified."
            : "Doctor did not confirm a supported Codex version. Managed mode remains experimental and unverified."
    }
}
