import Foundation
import Darwin
import Testing
import CodexHubCore
@testable import CodexHubCollector

// Run alone, since the counters cover the whole process:
// TOKLOOM_COST=1 swift test --build-system native --disable-xctest --filter RefreshCost

private let wanted = ProcessInfo.processInfo.environment["TOKLOOM_COST"] == "1"
nonisolated(unsafe) private let task = mach_task_self_

private struct Usage {
    let syscalls: Int, cpu: Double
    static func now() -> Usage {
        var events = task_events_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &events) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(task, task_flavor_t(TASK_EVENTS_INFO), $0, &count) }
        }
        var rusage = rusage()
        getrusage(RUSAGE_SELF, &rusage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return Usage(syscalls: Int(events.syscalls_unix), cpu: seconds(rusage.ru_utime) + seconds(rusage.ru_stime))
    }
}

private func measure(_ name: String, passes: Int = 40, _ body: () async throws -> Void) async rethrows {
    let start = Usage.now(), clock = ContinuousClock(), begun = clock.now
    for _ in 0..<passes { try await body() }
    let end = Usage.now(), elapsed = begun.duration(to: clock.now)
    let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    print("cost \(name): \((end.syscalls - start.syscalls) / passes) syscalls, "
        + String(format: "%.2f ms cpu, %.2f ms wall per pass", (end.cpu - start.cpu) * 1_000 / Double(passes), milliseconds / Double(passes)))
}

private func write(_ text: String, to file: URL, modified: Date) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
}

/// Measured layout: 977 rollouts in 126 folders, 130 of them inside the seven-day retention.
private func codexHome(in root: URL) throws -> URL {
    let home = root.appendingPathComponent("codex")
    let line = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"ID\",\"cwd\":\"/project\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"output_tokens\":10}}}}\n"
    for index in 0..<977 {
        let folder = "sessions/2026/\(index % 12)/\(index % 112)"
        let modified = Date(timeIntervalSinceNow: index < 130 ? -3_600 : -30 * 86_400)
        try write(line.replacingOccurrences(of: "ID", with: "session-\(index)"), to: home.appendingPathComponent("\(folder)/rollout-\(index).jsonl"), modified: modified)
    }
    return home
}

/// Eight live sessions, each with thirty finished subagents and their meta files.
private func claudeHome(in root: URL) throws -> URL {
    let home = root.appendingPathComponent("claude")
    let modified = Date(timeIntervalSinceNow: -3_600)
    for session in 0..<8 {
        let id = UUID().uuidString.lowercased(), pid = 4_000 + session
        let status = "{\"pid\":\(pid),\"sessionId\":\"\(id)\",\"cwd\":\"/proj/x\(session)\",\"procStart\":\"Sat Oct 17 18:18:23 2026\",\"kind\":\"interactive\",\"entrypoint\":\"cli\",\"status\":\"idle\"}"
        try write(status, to: home.appendingPathComponent("sessions/\(pid).json"), modified: modified)
        let project = home.appendingPathComponent("projects/-proj-x\(session)")
        try write("", to: project.appendingPathComponent("\(id).jsonl"), modified: modified)
        for agent in 0..<30 {
            let folder = project.appendingPathComponent("\(id)/subagents")
            try write("{\"type\":\"user\"}\n", to: folder.appendingPathComponent("agent-a\(agent).jsonl"), modified: modified)
            try write("{\"agentType\":\"Explore\",\"finished\":true}", to: folder.appendingPathComponent("agent-a\(agent).meta.json"), modified: modified)
        }
    }
    return home
}

@Test(.enabled(if: wanted)) func RefreshCostOfAnIdleMachine() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = try LogCollector(codexHome: codexHome(in: root), metadataDirectory: root.appendingPathComponent("metadata"))
    let started = ClaudeCollector.parseProcStart("Sat Oct 17 18:18:23 2026")!
    let claude = try ClaudeCollector(claudeHome: claudeHome(in: root), processStart: { (ProcessIdentity(pid: $0, osStartTime: "1.000000"), started) })
    for _ in 0..<3 { _ = try await codex.refresh(); await claude.refresh(at: ProcessInfo.processInfo.systemUptime) }
    try await measure("LogCollector.refresh") { _ = try await codex.refresh() }
    await measure("ClaudeCollector.refresh") { await claude.refresh(at: ProcessInfo.processInfo.systemUptime) }
}
