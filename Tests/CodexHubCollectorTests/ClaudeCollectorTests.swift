import Foundation
import Testing
import CodexHubCore
@testable import CodexHubCollector

private let sessionID = "9e986fea-67c4-4e90-9cf4-4ee795bad596"
private let procStart = "Sat Oct 17 18:18:23 2026"
private let base = 1_792_261_200.0

private final class ClaudeSandbox {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    var home: URL { root.appendingPathComponent("claude") }
    var transcript: URL { home.appendingPathComponent("projects/-proj-x/\(sessionID).jsonl") }
    let formatter = ISO8601DateFormatter()

    init() throws {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: transcript.path, contents: Data())
        try status("idle")
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func collector(alive: Bool = true) -> ClaudeCollector {
        let started = ClaudeCollector.parseProcStart(procStart)!
        return ClaudeCollector(claudeHome: home, processStart: { pid in
            alive ? (ProcessIdentity(pid: pid, osStartTime: "1.000000"), started) : nil
        })
    }
    func status(_ value: String, kind: String = "interactive") throws {
        let json = "{\"pid\":4242,\"sessionId\":\"\(sessionID)\",\"cwd\":\"/proj/x\",\"procStart\":\"\(procStart)\",\"kind\":\"\(kind)\",\"entrypoint\":\"cli\",\"status\":\"\(value)\"}"
        try Data(json.utf8).write(to: home.appendingPathComponent("sessions/4242.json"))
    }
    func stamp(_ offset: Double) -> String { formatter.string(from: Date(timeIntervalSince1970: base + offset)) }
    func user(_ at: Double, result: String? = nil) -> String {
        let content = result.map { "[{\"type\":\"tool_result\",\"tool_use_id\":\"\($0)\"}]" } ?? "\"hello\""
        return "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"\(stamp(at))\",\"message\":{\"role\":\"user\",\"content\":\(content)}}\n"
    }
    func assistant(_ id: String, _ at: Double, output: Int, block: String = "text", stop: String = "end_turn",
                   sidechain: Bool = false, thinking: Int = 0) -> String {
        "{\"type\":\"assistant\",\"isSidechain\":\(sidechain),\"timestamp\":\"\(stamp(at))\",\"cwd\":\"/proj/x\",\"effort\":\"medium\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-opus-5-5\",\"stop_reason\":\"\(stop)\",\"content\":[{\"type\":\"\(block)\",\"id\":\"tool-\(id)\"}],\"usage\":{\"input_tokens\":2,\"cache_read_input_tokens\":100,\"cache_creation_input_tokens\":10,\"output_tokens\":\(output),\"output_tokens_details\":{\"thinking_tokens\":\(thinking)},\"service_tier\":\"standard\"}}}\n"
    }
    func write(_ text: String) throws { try Data(text.utf8).write(to: transcript) }
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
}

@Test func C01HistoryCountsEachMessageOnceAndFoldsCacheIntoInput() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 400, block: "thinking", thinking: 30) +
                s.assistant("m1", 5, output: 400, block: "text") + s.user(6) + s.assistant("m2", 8, output: 50))
    let snapshot = await s.collector().refresh(at: 100, wall: base)
    let row = try #require(snapshot.sessions.first)
    let total = try #require(row.monitor.counter.baseline)
    #expect(total.outputTokens == 450)
    #expect(total.inputTokens == 2 * 112)
    #expect(total.cachedInputTokens == 200)
    #expect(total.reasoningOutputTokens == 30)
    #expect(row.provider == .claude && row.observedCLIRoot && row.process?.pid == 4242)
    #expect(row.monitor.key.homeID.hasPrefix("claude:") && row.model == "claude-opus-5-5")
    #expect(row.activity == .idle)
    #expect(row.usageDetails?.reasoningEffort == "medium" && row.usageDetails?.serviceTier == .standard)
}

@Test func C02RateUsesLastUserEntryAndExcludesToolTime() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.append(s.user(10) + s.assistant("m2", 14, output: 400, block: "tool_use", stop: "tool_use"))
    let first = await collector.refresh(at: 101, wall: base)
    let working = try #require(first.sessions.first)
    #expect(working.activity == .toolRunning)
    #expect(abs(try #require(working.monitor.workAverageRate(at: 101)) - 100) < 1e-6)
    // A 30 s tool wait sits between the tool_result and the next request; it must not slow the rate.
    try s.append(s.user(44, result: "tool-m2") + s.assistant("m3", 46, output: 200))
    let second = try #require(await collector.refresh(at: 102, wall: base).sessions.first)
    #expect(abs(try #require(second.monitor.workAverageRate(at: 102)) - 100) < 1e-6)
    #expect(second.activity != .toolRunning)
    #expect(second.monitor.counter.baseline?.outputTokens == 650)
}

@Test func C03RateHoldsTenSecondsAfterIdleThenExpires() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.append(s.user(10) + s.assistant("m2", 12, output: 200))
    _ = await collector.refresh(at: 101, wall: base)
    try s.status("idle")
    let done = try #require(await collector.refresh(at: 102, wall: base).sessions.first)
    #expect(done.activity == .idle)
    #expect(try done.monitor.workAverageRate(at: 108) == 100)
    #expect(try done.monitor.workAverageRate(at: 113) == nil)
}

@Test func C04SidechainAndDeadProcessesAreIgnored() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50) + s.assistant("side", 5, output: 999, sidechain: true))
    let row = try #require(await s.collector().refresh(at: 100, wall: base).sessions.first)
    #expect(row.monitor.counter.baseline?.outputTokens == 50)
    #expect(await s.collector(alive: false).refresh(at: 100, wall: base).sessions.isEmpty)
    try s.status("idle", kind: "background")
    #expect(await s.collector().refresh(at: 100, wall: base).sessions.isEmpty)
}

@Test func C05CombinedFrameSumsClaudeAndOtherMonitors() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.append(s.user(10) + s.assistant("m2", 12, output: 200))
    let claude = try #require(await collector.refresh(at: 101, wall: base).sessions.first)
    let key = ThreadKey(homeID: "/codex", runID: nil, threadID: "codex-thread")
    var codex = ThreadMonitor(key: key, source: .rolloutLog, epoch: "e")
    try codex.setConnectivity(.connected, at: 100)
    try codex.observeUsage(TokenUsage(outputTokens: 0), turnID: "h", source: .rolloutLog, epoch: "e", at: 100, historical: true)
    try codex.startTurn("t", at: 100)
    try codex.observeUsage(TokenUsage(outputTokens: 300), turnID: "t", source: .rolloutLog, epoch: "e", at: 101, rateInterval: .excludingTools(2))
    let frame = try ReportedFrame(monitors: [claude.monitor, codex], verifiedIndependentThreads: [claude.monitor.key, key], at: 101)
    #expect(abs(try #require(frame.tokensPerSecond) - 250) < 1e-6)
    #expect(frame.measuredRuns == 2)
}

private extension ClaudeSandbox {
    var subagents: URL { transcript.deletingLastPathComponent().appendingPathComponent("\(sessionID)/subagents") }
    /// One record of a subagent transcript; those live in their own file with `isSidechain: true`.
    func subRecord(_ type: String, _ id: String, _ at: Double, output: Int = 0, block: String = "text", stop: String = "end_turn", model: String = "claude-haiku-4-5") -> String {
        if type == "user" {
            return "{\"type\":\"user\",\"isSidechain\":true,\"agentId\":\"a1\",\"timestamp\":\"\(stamp(at))\",\"message\":{\"role\":\"user\",\"content\":\"probe\"}}\n"
        }
        return "{\"type\":\"assistant\",\"isSidechain\":true,\"agentId\":\"a1\",\"timestamp\":\"\(stamp(at))\",\"cwd\":\"/sub/cwd\",\"effort\":\"low\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"stop_reason\":\"\(stop)\",\"content\":[{\"type\":\"\(block)\",\"id\":\"sub-tool-\(id)\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":\(output),\"service_tier\":\"standard\"}}}\n"
    }
    func writeSubagent(_ text: String, name: String = "agent-a1.jsonl") throws {
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: subagents.appendingPathComponent(name))
    }
    func appendSubagent(_ text: String, name: String = "agent-a1.jsonl") throws {
        let handle = try FileHandle(forWritingTo: subagents.appendingPathComponent(name))
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
}

@Test func K01SubagentOutputCountsTowardTheParentSessionAndItsRate() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    // The parent launches a subagent and waits on it (a pending tool); the subagent streams in its own file.
    try s.append(s.user(10) + s.assistant("m2", 14, output: 400, block: "tool_use", stop: "tool_use"))
    try s.writeSubagent(s.subRecord("user", "", 20) + s.subRecord("assistant", "s1", 30, output: 1000))
    let row = try #require(await collector.refresh(at: 101, wall: base).sessions.first)
    #expect(row.monitor.counter.baseline?.outputTokens == 50 + 400 + 1000)
    #expect(row.activity == .toolRunning)
    // 1000 subagent tokens over the 10 s from its prompt, plus the parent's own 400 over 4 s.
    #expect(abs(try #require(row.monitor.workAverageRate(at: 101)) - 1400.0 / 14.0) < 1e-6)
}

@Test func K02SubagentRecordsNeverChangeTheParentsModelToolsOrIdentity() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.writeSubagent(s.subRecord("user", "", 20) + s.subRecord("assistant", "s1", 30, output: 100, block: "tool_use", stop: "tool_use"))
    let row = try #require(await collector.refresh(at: 101, wall: base).sessions.first)
    #expect(row.model == "claude-opus-5-5")                       // not the subagent's haiku
    #expect(row.usageDetails?.reasoningEffort == "medium")         // not the subagent's effort
    #expect(row.activity != .toolRunning)                          // a subagent's own tool_use is not the parent's tool wait
}

@Test func K03SubagentHistoryAtFirstSightIsCountedButNotRated() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 700))
    let row = try #require(await s.collector().refresh(at: 100, wall: base).sessions.first)
    #expect(row.monitor.counter.baseline?.outputTokens == 750)
    #expect(try row.monitor.workAverageRate(at: 100) == nil)
}

@Test func K04SubagentFileGrowthIsReadIncrementallyAndEachMessageCountsOnce() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.writeSubagent(s.subRecord("user", "", 20) + s.subRecord("assistant", "s1", 24, output: 300))
    _ = await collector.refresh(at: 101, wall: base)
    try s.appendSubagent(s.subRecord("assistant", "s1", 25, output: 300) + s.subRecord("assistant", "s2", 29, output: 200))
    let row = try #require(await collector.refresh(at: 102, wall: base).sessions.first)
    #expect(row.monitor.counter.baseline?.outputTokens == 50 + 300 + 200)
}
