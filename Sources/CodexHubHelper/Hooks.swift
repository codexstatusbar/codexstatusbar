import Foundation
import Darwin
import CryptoKit

// Hooks are an optional status source, never a token or thread-identity authority.
enum Hooks {
    static let events = ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "Interrupt", "PreToolUse", "PostToolUse"]
    static let limit = 4 * 1024 * 1024
    static var root: String { NSHomeDirectory() + "/Library/Application Support/CodexHub" }

    struct Manifest: Codable {
        let version: Int
        let home: String
        let installationID: String
        let command: String
        let events: [String]
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func identifier(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95].contains($0) }) else { return nil }
        return text
    }

    static func directory(_ path: String, create: Bool = false) throws -> Int32 {
        let fd = try privateDirectory(path, createFrom: create ? root : path + "/not-created")
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd); throw HelperError("Hook directory has unsafe ownership or permissions")
        }
        return fd
    }

    static func readFile(_ directory: Int32, _ name: String, maximum: Int = limit) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        try systemCheck(fd >= 0, "open hook file")
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size <= maximum else {
            throw HelperError("Hook file has unsafe type, owner, permissions or size")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            try systemCheck(n >= 0, "read hook file")
            if n == 0 { return data }
            guard data.count + n <= maximum else { throw HelperError("Hook file exceeds bound") }
            data.append(contentsOf: buffer.prefix(n))
        }
    }

    static func createFile(_ directory: Int32, _ name: String, _ data: Data, executable: Bool = false) throws {
        let fd = try privateFile(in: directory, name: name)
        defer { close(fd) }
        try systemCheck(writeAll(fd, data) && fsync(fd) == 0, "write hook file")
        if executable { try systemCheck(fchmod(fd, 0o700) == 0, "recorder permissions") }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func command(_ path: String, _ home: String, _ id: String) -> String {
        "\(quote(path + "/recorder")) _hook-record --home \(quote(home)) --installation \(quote(id))"
    }
    static func entry(_ command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command, "timeout": 1]]]
    }

    static func manifest(_ data: Data?, home: String, path: String) throws -> Manifest? {
        guard let data else { return nil }
        guard let value = try? JSONDecoder().decode(Manifest.self, from: data), value.version == 1,
              UUID(uuidString: value.installationID)?.uuidString == value.installationID,
              value.home == home, value.events == events,
              value.command == command(path + "/" + value.installationID, home, value.installationID) else {
            throw HelperError("Hook installation manifest conflicts; no changes made")
        }
        return value
    }

    static func status(_ state: String, home: String, installation: String? = nil) throws {
        var output: [String: Any] = ["schema_version": 1, "state": state, "trust": "manual_review_required",
            "runtime_verified": false, "codex_home_id": hash(home)]
        if let installation { output["installation_id"] = installation }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func run(_ arguments: [String]) throws {
        guard let action = arguments.first, ["install", "uninstall", "status"].contains(action) else {
            throw HelperError("Usage: hooks install|uninstall|status --home /absolute/CODEX_HOME [--consent]")
        }
        var args = Array(arguments.dropFirst()), home: String?, consent = false
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--home", home == nil, !args.isEmpty { home = args.removeFirst() }
            else if key == "--consent", !consent { consent = true }
            else { throw HelperError("Unsupported hook option") }
        }
        guard let home, home.hasPrefix("/"), URL(fileURLWithPath: home).standardizedFileURL.path == home else {
            throw HelperError("hooks requires explicit normalized absolute --home")
        }
        guard action == "status" || consent else { throw HelperError("Hook mutation requires explicit --consent; /hooks trust remains manual") }
        let homeFD = try directory(home)
        defer { close(homeFD) }
        // Directory lock serializes Hub mutations without adding a user-config lock file.
        try systemCheck(flock(homeFD, LOCK_EX | LOCK_NB) == 0, "lock hook home")
        defer { flock(homeFD, LOCK_UN) }
        let path = root + "/hooks/" + hash(home)
        var stateFD: Int32
        do { stateFD = try directory(path, create: action == "install") }
        catch {
            if action == "status", errno == ENOENT { try status("not_installed", home: home); return }
            throw error
        }
        defer { close(stateFD) }
        let manifestData = try readFile(stateFD, "manifest.json")
        let installed = try manifest(manifestData, home: home, path: path)
        let original = try readFile(homeFD, "hooks.json")
        var document: [String: Any] = [:]
        if let original {
            try rejectDuplicateKeys(original)
            guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw HelperError("hooks.json must be an object")
            }
            document = object
        }
        guard document["hooks"] == nil || document["hooks"] is [String: Any] else { throw HelperError("Invalid hooks map") }
        var map = document["hooks"] as? [String: Any] ?? [:]
        for value in map.values {
            guard let groups = value as? [[String: Any]], groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else {
                throw HelperError("Invalid hook entries; no changes made")
            }
        }
        if action == "status" {
            let complete = installed.map { owner in events.allSatisfy { event in
                (map[event] as? [[String: Any]] ?? []).contains { NSDictionary(dictionary: $0).isEqual(to: entry(owner.command)) }
            } } ?? false
            try status(installed == nil ? "not_installed" : complete ? "installed" : "conflict", home: home, installation: installed?.installationID)
            return
        }
        if action == "install", installed != nil { throw HelperError("Already installed; inspect status and uninstall before reinstalling") }
        if action == "uninstall", installed == nil { throw HelperError("No owned installation manifest; refusing removal") }
        // An orphaned Hub command requires explicit recovery, never adoption.
        if installed == nil, String(data: original ?? Data(), encoding: .utf8)?.contains("_hook-record") == true {
            throw HelperError("Conflicting recorder entries; no changes made")
        }
        let id = installed?.installationID ?? UUID().uuidString
        let installPath = path + "/" + id
        let owner = installed ?? Manifest(version: 1, home: home, installationID: id,
                                          command: command(installPath, home, id), events: events)
        for event in events {
            var groups = map[event] as? [[String: Any]] ?? []
            if action == "install" { groups.append(entry(owner.command)) }
            else {
                // Modified wrappers or handlers are foreign; refuse instead of deleting them.
                for group in groups {
                    let handlers = group["hooks"] as? [[String: Any]] ?? []
                    if handlers.contains(where: { ($0["command"] as? String) == owner.command }),
                       !NSDictionary(dictionary: group).isEqual(to: entry(owner.command)) {
                        throw HelperError("Owned hook was modified; refusing removal")
                    }
                }
                groups.removeAll { NSDictionary(dictionary: $0).isEqual(to: entry(owner.command)) }
            }
            map[event] = groups
        }
        document["hooks"] = map
        let merged = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let installFD = try directory(installPath, create: true)
        defer { close(installFD) }
        if action == "install" {
            guard let executableURL = Bundle.main.executableURL else { throw HelperError("Recorder executable unavailable") }
            let executable = executableURL.resolvingSymlinksInPath().path
            let executableParent = try directory(URL(fileURLWithPath: executable).deletingLastPathComponent().path)
            defer { close(executableParent) }
            guard let binary = try readFile(executableParent, URL(fileURLWithPath: executable).lastPathComponent, maximum: 128 * 1024 * 1024) else {
                throw HelperError("Recorder binary unavailable")
            }
            try createFile(installFD, "recorder", binary, executable: true)
            try createFile(stateFD, "manifest.json", JSONEncoder().encode(owner))
        }
        // The backup is exclusive, private and durable before touching configuration.
        if let original { try createFile(installFD, "hooks-backup-\(UUID().uuidString).json", original) }
        let staging = ".codex-hub-\(UUID().uuidString).json"
        try createFile(homeFD, staging, merged)
        var removeStaging = true
        defer { if removeStaging { unlinkat(homeFD, staging, 0) } }
        guard try readFile(homeFD, "hooks.json") == original else { throw HelperError("hooks.json changed concurrently; backup retained") }
        // EXCL also prevents overwriting a file created since an absent-file snapshot.
        if original == nil {
            try systemCheck(renameatx_np(homeFD, staging, homeFD, "hooks.json", UInt32(RENAME_EXCL)) == 0, "publish hooks")
        } else {
            try systemCheck(renameatx_np(homeFD, staging, homeFD, "hooks.json", UInt32(RENAME_SWAP)) == 0, "merge hooks")
            if (try? readFile(homeFD, staging)) != original {
                // Never discard a displaced version if rollback cannot be completed.
                removeStaging = false
                if (try? readFile(homeFD, "hooks.json")) == merged,
                   renameatx_np(homeFD, staging, homeFD, "hooks.json", UInt32(RENAME_SWAP)) == 0 {
                    removeStaging = true
                }
                throw HelperError("Concurrent hook replacement detected; recover using retained backup/staging files")
            }
        }
        try systemCheck(fsync(homeFD) == 0, "sync hooks directory")
        if action == "uninstall" {
            guard try readFile(stateFD, "manifest.json") == manifestData else { throw HelperError("Manifest changed; retained for recovery") }
            try systemCheck(unlinkat(stateFD, "manifest.json", 0) == 0, "remove installation marker")
        }
        print("Hooks \(action == "install" ? "installed" : "uninstalled"). Backups and recorder retained.\nReview /hooks: exact hook hashes still require your manual trust; trust/config.toml unchanged.")
    }

    static func record(_ arguments: [String]) {
        // Always return neutral JSON, including malformed inputs and disk failures.
        defer { _ = writeAll(STDOUT_FILENO, Data("{}\n".utf8)) }
        do {
            guard arguments.count == 4, arguments[0] == "--home", arguments[2] == "--installation",
                  UUID(uuidString: arguments[3])?.uuidString == arguments[3] else { return }
            let home = arguments[1], id = arguments[3]
            guard home.hasPrefix("/"), URL(fileURLWithPath: home).standardizedFileURL.path == home else { return }
            let path = root + "/hooks/" + hash(home)
            let parent = try directory(path)
            defer { close(parent) }
            guard let owner = try manifest(readFile(parent, "manifest.json"), home: home, path: path), owner.installationID == id else { return }
            let flags = fcntl(STDIN_FILENO, F_GETFL)
            guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
            let deadline = DispatchTime.now().uptimeNanoseconds + 150_000_000
            var data = Data(), bytes = [UInt8](repeating: 0, count: 8192), eof = false
            while DispatchTime.now().uptimeNanoseconds < deadline {
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 10) >= 0 else { return }
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { eof = true; break }
                if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; return }
                guard data.count + count <= 256 * 1024 else { return }
                data.append(contentsOf: bytes.prefix(count))
            }
            guard eof, let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = identifier(input["session_id"]), let event = input["hook_event_name"] as? String,
                  events.contains(event) else { return }
            let turn = identifier(input["turn_id"]), tool = identifier(input["tool_use_id"])
            if !["SessionStart", "SessionEnd"].contains(event), turn == nil { return }
            if ["PreToolUse", "PostToolUse"].contains(event), tool == nil { return }
            var output: [String: Any] = ["hub_schema_version": 1, "hub_source": "hook", "codex_home_id": hash(home),
                "installation_id": id, "session_id": session, "hook_event_name": event,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "received_monotonic_ns": String(DispatchTime.now().uptimeNanoseconds)]
            if let turn { output["turn_id"] = turn }
            if let tool, ["PreToolUse", "PostToolUse"].contains(event) { output["tool_use_id"] = tool }
            var line = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]); line.append(10)
            let directoryFD = try directory(path + "/" + id)
            defer { close(directoryFD) }
            let fd = openat(directoryFD, "events.jsonl", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
            defer { flock(fd, LOCK_UN) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size + Int64(line.count) <= limit else { return }
            if !writeAll(fd, line) { _ = ftruncate(fd, info.st_size) }
        } catch { /* Fail open: no raw input, errors, decisions or context escape the recorder. */ }
    }

    // JSONSerialization accepts duplicate keys; reject ambiguous documents before merging.
    static func rejectDuplicateKeys(_ data: Data) throws {
        let bytes = Array(data); var index = 0
        func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func string() throws -> String {
            let start = index
            guard index < bytes.count, bytes[index] == 34 else { throw HelperError("Invalid hook JSON") }
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == 34 {
                    index += 1
                    guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else { throw HelperError("Invalid hook key") }
                    return value
                }
                index += 1
            }
            throw HelperError("Invalid hook JSON string")
        }
        func value(_ depth: Int) throws {
            guard depth < 64 else { throw HelperError("Hook JSON nesting exceeds bound") }
            whitespace(); guard index < bytes.count else { throw HelperError("Invalid hook JSON") }
            if bytes[index] == 34 { _ = try string(); return }
            if bytes[index] == 123 || bytes[index] == 91 {
                let object = bytes[index] == 123, end: UInt8 = bytes[index] == 123 ? 125 : 93
                index += 1; whitespace(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == end { index += 1; return }
                while index < bytes.count {
                    if object {
                        whitespace(); let key = try string()
                        guard keys.insert(key).inserted else { throw HelperError("Duplicate hook JSON key") }
                        whitespace(); guard index < bytes.count, bytes[index] == 58 else { throw HelperError("Invalid hook JSON") }
                        index += 1
                    }
                    try value(depth + 1); whitespace()
                    guard index < bytes.count else { throw HelperError("Invalid hook JSON") }
                    if bytes[index] == end { index += 1; return }
                    guard bytes[index] == 44 else { throw HelperError("Invalid hook JSON") }
                    index += 1
                }
                throw HelperError("Invalid hook JSON")
            }
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        }
        try value(0)
        _ = try JSONSerialization.jsonObject(with: data)
    }
}
