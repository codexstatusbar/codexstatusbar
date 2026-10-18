import Foundation
import Darwin
import CryptoKit

// crt_externs.h is not exported by the Swift Darwin module; preserve envp verbatim.
@_silgen_name("_NSGetEnviron")
private func currentEnvironment() -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>

let help = """
Usage: codex-hub help
       codex-hub doctor [--codex /absolute/path/to/codex]
       codex-hub run --experimental [--server-timing] [--codex /absolute/path/to/codex]

Experimental managed run: Codex 0.163.0 only; G0 and real TUI semantics UNVERIFIED.
Starts an owned app-server, relays Unix HTTP Upgrade/WebSocket bytes, then execs
Codex TUI --remote with the current working directory and environment.
No extra TUI options, prompts, profiles, resume, fork or server overrides are
accepted: their argument routing has not been verified. Configure Codex normally.
Live estimates use bundled tokenization for supported OpenAI model mappings;
unknown models remain unavailable.
--server-timing opts this managed invocation into runtime_metrics and local,
metadata-only server timing capture; no global config or provider request is
made by installing the app. Raw TBT is not a verified decode-rate contract.
Doctor checks executable version only; it does not start a session or prove G0.
"""

func resolveCodex(_ explicit: String?) throws -> String {
    if let explicit {
        guard explicit.hasPrefix("/"), access(explicit, X_OK) == 0 else { throw HelperError("--codex requires an executable absolute path") }
        return URL(fileURLWithPath: explicit).resolvingSymlinksInPath().path
    }
    for path in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(path)).appendingPathComponent("codex").path
        if access(candidate, X_OK) == 0 { return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path }
    }
    throw HelperError("codex not found in PATH; use --codex /absolute/path")
}

func supportedVersion(_ executable: String) throws -> Bool {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["--version"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let fd = output.fileHandleForReading.fileDescriptor
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
    var bytes = Data(), chunk = [UInt8](repeating: 0, count: 1024)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let count = read(fd, &chunk, chunk.count)
        if count > 0 {
            bytes.append(contentsOf: chunk.prefix(count))
            if bytes.count > 4096 { break }
        }
        if !process.isRunning { break }
        usleep(10_000)
    }
    if process.isRunning {
        // Process still owns this unreaped child PID; never signal a discovered PID.
        process.terminate()
        throw HelperError("Codex version query exceeded its bound")
    }
    let count = read(fd, &chunk, chunk.count)
    if count > 0 { bytes.append(contentsOf: chunk.prefix(count)) }
    return process.terminationStatus == 0 && String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli 0.163.0"
}

func execTUI(_ executable: String, socket: String) throws -> Never {
    let strings = [executable, "--remote", "unix://" + socket]
    let arguments = strings.map { strdup($0) } + [nil]
    defer { arguments.forEach { free($0) } }
    arguments.withUnsafeBufferPointer { _ = execv(executable, $0.baseAddress!) }
    throw HelperError("TUI exec failed (errno \(errno))")
}

func launch(_ executable: String, serverTiming: Bool) throws -> Never {
    let run = UUID().uuidString.lowercased()
    var template = Array("/private/tmp/codex-hub-XXXXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else { throw HelperError("Cannot create runtime directory") }
    let runtime = String(cString: created)
    let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex").resolvingSymlinksInPath().standardizedFileURL.path
    let homeID = SHA256.hash(data: Data(home.utf8)).map { String(format: "%02x", $0) }.joined()
    let root = NSHomeDirectory() + "/Library/Application Support/CodexHub"
    let metadata = root + "/managed-runs/" + homeID + "/sessions/" + run
    let directory: Int32
    do { directory = try privateDirectory(metadata, createFrom: root) }
    catch { rmdir(runtime); throw error }
    close(directory)
    let ready = Pipe()
    var actions: posix_spawn_file_actions_t?
    try systemCheck(posix_spawn_file_actions_init(&actions) == 0, "spawn actions")
    defer { posix_spawn_file_actions_destroy(&actions) }
    let null = open("/dev/null", O_RDWR | O_CLOEXEC)
    try systemCheck(null >= 0, "open null device")
    defer { close(null) }
    for (source, target) in [(null, STDIN_FILENO), (ready.fileHandleForWriting.fileDescriptor, STDOUT_FILENO), (null, STDERR_FILENO)] {
        try systemCheck(posix_spawn_file_actions_adddup2(&actions, source, target) == 0, "spawn descriptor")
    }
    try systemCheck(posix_spawn_file_actions_addclose(&actions, ready.fileHandleForReading.fileDescriptor) == 0, "spawn close")
    guard let helper = Bundle.main.executableURL?.path else { throw HelperError("Cannot resolve helper executable") }
    let strings = [helper, "_serve", executable, runtime, metadata, run, homeID, String(getpid()), serverTiming ? "timing" : "none"]
    let argv = strings.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var attributes: posix_spawnattr_t?
    try systemCheck(posix_spawnattr_init(&attributes) == 0, "spawn attributes")
    defer { posix_spawnattr_destroy(&attributes) }
    try systemCheck(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0, "spawn close-on-exec")
    var child: pid_t = 0
    let spawnResult = argv.withUnsafeBufferPointer {
        posix_spawn(&child, helper, &actions, &attributes, $0.baseAddress!, currentEnvironment().pointee)
    }
    guard spawnResult == 0 else { rmdir(runtime); throw HelperError("Helper spawn failed (errno \(spawnResult))") }
    ready.fileHandleForWriting.closeFile()
    var polling = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
    let result = poll(&polling, 1, 15_000)
    var byte: UInt8 = 0
    guard result > 0, read(polling.fd, &byte, 1) == 1, byte == 82 else {
        kill(child, SIGTERM)
        throw HelperError("Managed helper could not become ready; no TUI was started")
    }
    ready.fileHandleForReading.closeFile()
    do { try execTUI(executable, socket: runtime + "/relay.sock") }
    catch { kill(child, SIGTERM); throw error }

}

func serve(_ arguments: [String]) throws {
    guard arguments.count == 7, ["timing", "none"].contains(arguments[6]), let tuiPID = Int32(arguments[5]), tuiPID == getppid(),
          UUID(uuidString: arguments[3]) != nil else { throw HelperError("Internal helper must be started by launcher") }
    let executable = arguments[0], runtime = arguments[1], metadata = arguments[2], run = arguments[3], home = arguments[4]
    var info = stat()
    guard lstat(runtime, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { throw HelperError("Unsafe runtime directory") }
    let tuiIdentity = try processIdentity(tuiPID)
    try systemCheck(setsid() >= 0, "detach helper")
    umask(0o077)
    let relayPath = runtime + "/relay.sock", serverPath = runtime + "/server.sock"
    defer { unlink(relayPath); unlink(serverPath); rmdir(runtime) }
    let listener = try unixSocket(relayPath, listen: true)
    let lifetime = RelayLifetime()
    lifetime.add(listener)
    defer { lifetime.closeSocket(listener) }
    let server = Process()
    server.executableURL = URL(fileURLWithPath: executable)
    server.arguments = ["app-server", "--listen", "unix://" + serverPath]
    server.standardInput = FileHandle.nullDevice
    server.standardOutput = FileHandle.nullDevice
    let timingPipe = arguments[6] == "timing" ? Pipe() : nil
    if let timingPipe {
        server.arguments?.append(contentsOf: ["--enable", "runtime_metrics"])
        var environment = ProcessInfo.processInfo.environment
        environment["RUST_LOG"] = "off,codex_api::responses_websocket_timing=trace"
        environment["NO_COLOR"] = "1"
        server.environment = environment
        server.standardError = timingPipe
    } else { server.standardError = FileHandle.nullDevice }
    try server.run()
    timingPipe?.fileHandleForWriting.closeFile()
    let signals = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { lifetime.interrupt(); if server.isRunning { server.terminate() } }
        source.resume()
        return source
    }
    let parentWatch = DispatchSource.makeTimerSource(queue: .global())
    parentWatch.schedule(deadline: .now() + 1, repeating: 1)
    parentWatch.setEventHandler {
        if getppid() != tuiPID { lifetime.interrupt(); if server.isRunning { server.terminate() } }
    }
    parentWatch.resume()
    defer { signals.forEach { $0.cancel() }; parentWatch.cancel() }
    defer {
        if server.isRunning { server.terminate() }
        let until = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while server.isRunning && DispatchTime.now().uptimeNanoseconds < until { usleep(10_000) }
        if server.isRunning { kill(server.processIdentifier, SIGKILL) }
        server.waitUntilExit()
    }
    let root = NSHomeDirectory() + "/Library/Application Support/CodexHub"
    let directory = try privateDirectory(metadata, createFrom: root)
    let identities: [String: Any] = ["tui": tuiIdentity, "app_server": try processIdentity(server.processIdentifier), "relay": try processIdentity(getpid())]
    let observer = try Observation(directory: directory, run: run, home: home, processes: identities)
    timingPipe?.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil }
        else { observer.submitTiming(data) }
    }
    defer {
        timingPipe?.fileHandleForReading.readabilityHandler = nil
        timingPipe?.fileHandleForReading.closeFile()
        observer.finish()
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    var upstream: Int32 = -1
    while server.isRunning && DispatchTime.now().uptimeNanoseconds < deadline {
        var socketInfo = stat()
        if lstat(serverPath, &socketInfo) == 0 {
            guard socketInfo.st_uid == getuid(), socketInfo.st_mode & S_IFMT == S_IFSOCK,
                  socketInfo.st_mode & 0o777 == 0o600 else { throw HelperError("Unsafe app-server socket") }
            if let connected = try? unixSocket(serverPath, listen: false) { upstream = connected; break }
        }
        usleep(20_000)
    }
    guard upstream >= 0 else { throw HelperError("App-server socket did not become ready") }
    lifetime.add(upstream)
    defer { lifetime.closeSocket(upstream) }
    guard writeAll(STDOUT_FILENO, Data([82])) else { throw HelperError("Launcher disconnected") }
    close(STDOUT_FILENO)
    var polling = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&polling, 1, 30_000) > 0 else { throw HelperError("TUI did not connect") }
    let client = accept(listener, nil, nil)
    try systemCheck(client >= 0, "accept")
    lifetime.add(client)
    defer { lifetime.closeSocket(client) }
    try sameUser(client)
    var one: Int32 = 1
    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    _ = fcntl(client, F_SETFD, FD_CLOEXEC)
    let group = DispatchGroup()
    let serverFD = upstream
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        pump(from: client, to: serverFD, observer: observer, clientDirection: true)
        group.leave()
    }
    pump(from: upstream, to: client, observer: observer)
    group.wait()
}

func pump(from source: Int32, to destination: Int32, observer: Observation?, clientDirection: Bool = false) {
    var bytes = [UInt8](repeating: 0, count: 32_768)
    while true {
        let count = read(source, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 {
            // EOF preserves the other half of the stream; hard errors unblock both pumps.
            shutdown(destination, SHUT_WR)
            if count < 0 { shutdown(source, SHUT_RDWR); shutdown(destination, SHUT_RDWR) }
            return
        }
        let data = Data(bytes.prefix(count))
        if clientDirection { observer?.submitClient(data) }
        guard writeAll(destination, data) else {
            shutdown(source, SHUT_RDWR); shutdown(destination, SHUT_RDWR); return
        }
        if !clientDirection { observer?.submit(data) }
    }
}

func main() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let command = arguments.isEmpty ? "help" : arguments.removeFirst()
    if command == "_serve" { try serve(arguments); return }
    if ["help", "--help", "-h"].contains(command) {
        guard arguments.isEmpty else { throw HelperError("help accepts no options") }
        print(help); return
    }
    guard ["doctor", "run"].contains(command) else { throw HelperError("Unsupported command; use codex-hub help") }
    var explicit: String?, experimental = false, serverTiming = false
    while !arguments.isEmpty {
        let option = arguments.removeFirst()
        if option == "--codex", explicit == nil, !arguments.isEmpty { explicit = arguments.removeFirst() }
        else if option == "--experimental", command == "run", !experimental { experimental = true }
        else if option == "--server-timing", command == "run", !serverTiming { serverTiming = true }
        else { throw HelperError("Unsupported or unverified option; no arguments were forwarded") }
    }
    if command == "run" && !experimental { throw HelperError("Managed run requires --experimental; G0 is unverified") }
    let executable = try resolveCodex(explicit)
    let supported = try supportedVersion(executable)
    if command == "doctor" {
        print("Executable: \(executable)\nCodex 0.163.0: \(supported ? "matched" : "unsupported")\nManaged relay: experimental, G0 unverified\nLive: supported model mappings only; runtime unverified\nHook installer: optional; hooks status --home PATH (/hooks trust required)")
        if !supported { throw HelperError("Unsupported Codex version") }
        return
    }
    guard supported else { throw HelperError("Managed run supports only the investigated codex-cli 0.163.0") }
    FileHandle.standardError.write(Data("Experimental managed relay; G0/TUI behavior unverified.\n".utf8))
    try launch(executable, serverTiming: serverTiming)
}

do { try main() }
catch {
    FileHandle.standardError.write(Data("codex-hub: \(error)\n".utf8))
    exit(1)
}
