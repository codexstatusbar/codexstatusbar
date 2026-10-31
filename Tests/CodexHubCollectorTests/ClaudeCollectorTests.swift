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
    /// `finished` writes the `agent-a1.meta.json` Claude Code keeps beside the transcript.
    func writeSubagent(_ text: String, finished: Bool? = nil, modified: Double? = nil) throws {
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let file = subagents.appendingPathComponent("agent-a1.jsonl")
        try Data(text.utf8).write(to: file)
        if let finished { try Data("{\"agentType\":\"Explore\",\"finished\":\(finished)}".utf8).write(to: subagents.appendingPathComponent("agent-a1.meta.json")) }
        if let modified { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path) }
    }
}

private func child(of snapshot: CollectorSnapshot) -> SessionSnapshot? { snapshot.sessions.first { $0.parentThreadID == sessionID } }

@Test func K01SubagentAppearsAsItsOwnSessionLinkedToItsParent() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.append(s.user(10) + s.assistant("m2", 14, output: 400, block: "tool_use", stop: "tool_use"))
    try s.writeSubagent(s.subRecord("user", "", 20) + s.subRecord("assistant", "s1", 30, output: 1000), finished: false)
    let snapshot = await collector.refresh(at: 101, wall: base)
    #expect(snapshot.sessions.count == 2)
    let parent = try #require(snapshot.sessions.first { $0.parentThreadID == nil })
    let sub = try #require(child(of: snapshot))
    #expect(sub.provider == .claude && sub.observedCLIRoot == false && sub.process == parent.process)
    #expect(sub.monitor.counter.baseline?.outputTokens == 1000)       // its own tokens...
    #expect(parent.monitor.counter.baseline?.outputTokens == 450)     // ...never added to the parent's
    #expect(sub.model == "claude-haiku-4-5" && parent.model == "claude-opus-5-5")
    #expect(sub.monitor.key.threadID != parent.monitor.key.threadID)
    let subRate = try #require(try sub.monitor.workAverageRate(at: 101))
    #expect(abs(subRate - 100) < 1e-6)   // 1000 tokens over 10 s
}

@Test func K02RunningSubagentIsWorkingAndFinishedOneGoesIdle() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.writeSubagent(s.subRecord("user", "", 20) + s.subRecord("assistant", "s1", 30, output: 100, block: "tool_use", stop: "tool_use"), finished: false)
    let running = try #require(child(of: await collector.refresh(at: 101, wall: base)))
    #expect(running.activity != .idle && running.activity != .unknown)
    try s.writeSubagent(s.subRecord("user", "", 20) + s.subRecord("assistant", "s1", 30, output: 100), finished: true)
    let done = try #require(child(of: await collector.refresh(at: 102, wall: base)))
    #expect(done.activity == .idle)
}

@Test func K03SubagentHistoryCountsButIsNotRatedAndOldFinishedOnesAreSkipped() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 700), finished: true, modified: base - 60)
    let sub = try #require(child(of: await s.collector().refresh(at: 100, wall: base)))
    #expect(sub.monitor.counter.baseline?.outputTokens == 700)
    #expect(try sub.monitor.workAverageRate(at: 100) == nil)
    // A finished subagent untouched for hours would flood a long-lived session's list.
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 700), finished: true, modified: base - 7_200)
    #expect(child(of: await s.collector().refresh(at: 100, wall: base)) == nil)
}

@Test func K04SubagentsLeaveWithTheirSession() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 700), finished: false)
    #expect(await s.collector(alive: false).refresh(at: 100, wall: base).sessions.isEmpty)
}

@Test func K05SubagentOutputLeavesTheParentRateAlone() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.status("busy")
    try s.append(s.user(10) + s.assistant("m2", 14, output: 400, block: "tool_use", stop: "tool_use"))
    let alone = try #require(await collector.refresh(at: 101, wall: base).sessions.first)
    let before = try #require(try alone.monitor.workAverageRate(at: 101))
    try s.writeSubagent(s.subRecord("user", "", 20) + s.subRecord("assistant", "s1", 30, output: 5000), finished: false)
    let snapshot = await collector.refresh(at: 102, wall: base)
    let parent = try #require(snapshot.sessions.first { $0.parentThreadID == nil })
    let after = try #require(try parent.monitor.workAverageRate(at: 102))
    #expect(abs(after - before) < 1e-6)
}

@Test func K06ContextIsTheLastRequestsInputAgainstTheModelsWindow() async throws {
    let s = try ClaudeSandbox()
    // The helper's usage is input 2 + cache read 100 + cache write 10 per request; output never counts toward context.
    try s.writeModelCatalog(["claude-opus-5-5": 1_000_000])
    try s.write(s.user(0) + s.assistant("m1", 4, output: 900) + s.user(6) + s.assistant("m2", 8, output: 50))
    let row = try #require(await s.collector().refresh(at: 100, wall: base).sessions.first)
    #expect(row.usageDetails?.contextTokens == 112)
    #expect(row.usageDetails?.contextWindow == 1_000_000)
}

@Test func K07UnknownModelsShowContextTokensButNoWindow() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 70, model: "claude-haiku-4-5"), finished: true, modified: base - 60)
    let sub = try #require(child(of: await s.collector().refresh(at: 100, wall: base)))
    #expect(sub.usageDetails?.contextTokens == 1)        // the helper's subagent usage is input 1
    #expect(sub.usageDetails?.contextWindow == nil)
}

private extension ClaudeSandbox {
    /// Claude Code keeps the models' limits in `cache/model-catalog/<id>.json`.
    func writeModelCatalog(_ models: [String: Int], name: String = "catalog-1.json") throws {
        let directory = home.appendingPathComponent("cache/model-catalog")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = models.map { "{\"id\":\"\($0.key)\",\"runtime\":{\"max_input_tokens\":\($0.value)}}" }.joined(separator: ",")
        try Data("{\"version\":2,\"catalog\":{\"config\":{\"models\":[\(entries)]}}}".utf8).write(to: directory.appendingPathComponent(name))
    }
}

@Test func K08ContextWindowIsReadFromClaudeCodesModelCatalog() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeModelCatalog(["claude-opus-5-5": 200_000])      // overrides the 1M the documented table would say
    let row = try #require(await s.collector().refresh(at: 100, wall: base).sessions.first)
    #expect(row.usageDetails?.contextWindow == 200_000)
}

@Test func K09ModelsMissingFromTheCatalogHaveNoWindowAndNothingIsGuessed() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    // No catalog at all: the context tokens are known, the window is not.
    let without = try #require(await s.collector().refresh(at: 100, wall: base).sessions.first)
    #expect(without.usageDetails?.contextTokens == 112 && without.usageDetails?.contextWindow == nil)
    // A catalog that lists other models only, even a family the model belongs to, says nothing about this one.
    try s.writeModelCatalog(["claude-opus-5": 1_000_000, "claude-haiku-4-5-20251001": 200_000])
    let other = try #require(await s.collector().refresh(at: 100, wall: base).sessions.first)
    #expect(other.usageDetails?.contextWindow == nil)
}

@Test func K10ACatalogThatChangesIsReloaded() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeModelCatalog(["claude-opus-5-5": 200_000])
    let collector = s.collector()
    #expect(try #require(await collector.refresh(at: 100, wall: base).sessions.first).usageDetails?.contextWindow == 200_000)
    try s.writeModelCatalog(["claude-opus-5-5": 500_000], name: "catalog-2.json")   // a newer file replaces it
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: s.home.appendingPathComponent("cache/model-catalog/catalog-2.json").path)
    #expect(try #require(await collector.refresh(at: 101, wall: base).sessions.first).usageDetails?.contextWindow == 500_000)
}

private extension ClaudeSandbox {
    /// A second subagent file, so a session can have several.
    func writeSecondSubagent(_ text: String, finished: Bool, modified: Double) throws {
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let file = subagents.appendingPathComponent("agent-a2.jsonl")
        try Data(text.utf8).write(to: file)
        try Data("{\"finished\":\(finished)}".utf8).write(to: subagents.appendingPathComponent("agent-a2.meta.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
    }
}

@Test func K11TheParentCarriesTheTotalOfAllItsSubagentsEvenThoseNoLongerListed() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 700), finished: false)          // running
    try s.writeSecondSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s2", 9, output: 500), finished: true, modified: base - 7_200)   // done hours ago
    let snapshot = await s.collector().refresh(at: 100, wall: base)
    let parent = try #require(snapshot.sessions.first { $0.parentThreadID == nil })
    #expect(snapshot.sessions.count == 2)                                   // the old one is not listed...
    #expect(parent.subagentUsage?.outputTokens == 1_200)                    // ...but its tokens still belong to the session
    #expect(parent.monitor.counter.baseline?.outputTokens == 50)            // and the parent's own counter is untouched
}

@Test func K12ASubagentThatAgesOutKeepsCountingTowardTheParent() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 700), finished: true, modified: base - 60)
    let collector = s.collector()
    let early = await collector.refresh(at: 100, wall: base)
    #expect(early.sessions.count == 2 && early.sessions.first { $0.parentThreadID == nil }?.subagentUsage?.outputTokens == 700)
    let later = await collector.refresh(at: 101, wall: base + 7_200)         // two hours on: long past the listing window
    #expect(later.sessions.count == 1)
    #expect(later.sessions.first?.subagentUsage?.outputTokens == 700)       // the session total does not shrink
}

@Test func K13ASessionWithoutSubagentsHasNoSubagentTotal() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    #expect(try #require(await s.collector().refresh(at: 100, wall: base).sessions.first).subagentUsage == nil)
}

@Test func K14TwoProcessesOnTheSameSessionListItOnce() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let json = "{\"pid\":4343,\"sessionId\":\"\(sessionID)\",\"cwd\":\"/proj/x\",\"procStart\":\"\(procStart)\",\"kind\":\"interactive\",\"entrypoint\":\"cli\",\"status\":\"busy\"}"
    try Data(json.utf8).write(to: s.home.appendingPathComponent("sessions/4343.json"))
    let rows = await s.collector().refresh(at: 100, wall: base).sessions
    #expect(rows.count == 1 && Set(rows.map(\.monitor.key)).count == rows.count)
    #expect(rows.first?.process?.pid == 4343)
}

private extension ClaudeSandbox {
    func transcript(in folder: String) -> URL { home.appendingPathComponent("projects/-proj-\(folder)/\(sessionID).jsonl") }
    func writeTranscript(_ text: String, in folder: String) throws {
        let file = transcript(in: folder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.replacingOccurrences(of: "/proj/x", with: "/proj/\(folder)").utf8).write(to: file)
    }
    func appendTranscript(_ text: String, in folder: String) throws {
        let handle = try FileHandle(forWritingTo: transcript(in: folder))
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.replacingOccurrences(of: "/proj/x", with: "/proj/\(folder)").utf8))
    }
    func process(_ pid: Int, in folder: String, status: String = "idle") throws {
        let json = "{\"pid\":\(pid),\"sessionId\":\"\(sessionID)\",\"cwd\":\"/proj/\(folder)\",\"procStart\":\"\(procStart)\",\"kind\":\"interactive\",\"entrypoint\":\"cli\",\"status\":\"\(status)\"}"
        try Data(json.utf8).write(to: home.appendingPathComponent("sessions/\(pid).json"))
    }
    func exit(_ pid: Int) throws { try FileManager.default.removeItem(at: home.appendingPathComponent("sessions/\(pid).json")) }
    /// The session continued from a second folder: pid 4242 on /proj/x with 50 tokens, pid 4343 on /proj/y with 70.
    func continueInSecondFolder() throws {
        try writeTranscript(user(0) + assistant("m1", 4, output: 50), in: "x")
        try writeTranscript(user(0) + assistant("m2", 4, output: 70), in: "y")
        try process(4343, in: "y")
    }
    func writeSubagent(_ text: String, in folder: String, finished: Bool = true, modified: Double = base - 60) throws {
        let directory = transcript(in: folder).deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-a1.jsonl")
        try Data(text.utf8).write(to: file)
        try Data("{\"finished\":\(finished)}".utf8).write(to: directory.appendingPathComponent("agent-a1.meta.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
    }
}

private func row(_ snapshot: CollectorSnapshot, in folder: String) -> SessionSnapshot? {
    snapshot.sessions.first { $0.parentThreadID == nil && $0.cwd == "/proj/\(folder)" }
}

@Test func K15OneSessionIDContinuedFromTwoFoldersListsBothWorks() async throws {
    let s = try ClaudeSandbox()
    try s.continueInSecondFolder()
    let snapshot = await s.collector().refresh(at: 100, wall: base)
    #expect(snapshot.sessions.count == 2)
    let x = try #require(row(snapshot, in: "x")), y = try #require(row(snapshot, in: "y"))
    #expect(x.process?.pid == 4242 && x.monitor.counter.baseline?.outputTokens == 50)
    #expect(y.process?.pid == 4343 && y.monitor.counter.baseline?.outputTokens == 70)
    #expect(x.id != y.id && x.monitor.key != y.monitor.key)
    // One repeated key would throw here and hide every session of every provider.
    let keys = Set([x.monitor.key, y.monitor.key])
    #expect((try? ReportedFrame(monitors: [x.monitor, y.monitor], verifiedIndependentThreads: keys, at: 100)) != nil)
    for thread in [x, y].map(\.monitor.key.threadID) {
        // The chart archive rejects a thread over 256 bytes, so the id must not grow with the folder's path.
        #expect(thread.hasPrefix(sessionID + "@") && thread.utf8.count == sessionID.utf8.count + 9)
        #expect(ClaudeCollector.claudeID(ofThread: thread) == sessionID)
    }
}

@Test func K16ProcessesOnOneTranscriptShareARowWhileOtherTranscriptsKeepTheirs() async throws {
    let s = try ClaudeSandbox()
    try s.continueInSecondFolder()
    try s.process(4242, in: "x", status: "busy")
    try s.process(4343, in: "y", status: "idle")
    try s.process(4444, in: "y", status: "busy")
    let tied = await s.collector().refresh(at: 100, wall: base)
    #expect(tied.sessions.count == 2)
    #expect(try #require(row(tied, in: "y")).process?.pid == 4444)                       // equal start: the higher pid
    #expect(try #require(row(tied, in: "y")).activity != .idle)
    let started = ClaudeCollector.parseProcStart(procStart)!
    let collector = ClaudeCollector(claudeHome: s.home, processStart: { pid in
        (ProcessIdentity(pid: pid, osStartTime: "\(pid)"), pid == 4343 ? started + 1 : started)
    })
    let later = await collector.refresh(at: 100, wall: base)
    #expect(later.sessions.count == 2)
    #expect(try #require(row(later, in: "y")).process?.pid == 4343)                      // the later start wins over a higher pid
    #expect(try #require(row(later, in: "x")).process?.pid == 4242)
}

@Test func K17TheWorkingFolderPicksTheTranscriptAndTheScanOnlyFillsIn() async throws {
    let s = try ClaudeSandbox()
    try s.writeTranscript(s.user(0) + s.assistant("m1", 4, output: 11), in: "a")         // sorts first, so a scan would take it
    try s.writeTranscript(s.user(0) + s.assistant("m2", 4, output: 22), in: "y")
    try FileManager.default.removeItem(at: s.transcript)
    try s.exit(4242)
    try s.process(4343, in: "y")
    let own = await s.collector().refresh(at: 100, wall: base)
    #expect(own.sessions.count == 1 && own.sessions.first?.monitor.counter.baseline?.outputTokens == 22)
    // A folder with no transcript of its own joins the one the scan finds instead of adding a row.
    try s.process(4444, in: "z")
    let scanned = await s.collector().refresh(at: 100, wall: base)
    #expect(scanned.sessions.count == 2)
    let joined = try #require(scanned.sessions.first { $0.process?.pid == 4444 })
    #expect(joined.monitor.counter.baseline?.outputTokens == 11)
    #expect(scanned.sessions.first { $0.process?.pid == 4343 }?.monitor.counter.baseline?.outputTokens == 22)
}

@Test func K18TranscriptsSharingASessionIDNeverTouchEachOthersStateOrUsage() async throws {
    let s = try ClaudeSandbox()
    try s.continueInSecondFolder()
    let collector = s.collector()
    let first = await collector.refresh(at: 100, wall: base)
    let epoch = try #require(row(first, in: "x")).monitor.counter.epoch
    try s.process(4343, in: "y", status: "busy")
    try s.appendTranscript(s.user(10) + s.assistant("m3", 12, output: 200), in: "y")
    let second = await collector.refresh(at: 101, wall: base)
    let x = try #require(row(second, in: "x")), y = try #require(row(second, in: "y"))
    #expect(y.monitor.counter.baseline?.outputTokens == 270 && y.activity != .idle)
    let rate = try #require(try y.monitor.workAverageRate(at: 101))
    #expect(abs(rate - 100) < 1e-6)
    #expect(x.monitor.counter.baseline?.outputTokens == 50 && x.activity == .idle)
    #expect(x.monitor.counter.epoch == epoch)                                            // not reloaded by its neighbour
    #expect(try x.monitor.workAverageRate(at: 101) == nil)
}

@Test func K19ASharedSessionsIDsSurviveARestartAndDoNotDependOnStartOrder() async throws {
    let s = try ClaudeSandbox()
    try s.continueInSecondFolder()
    let first = await s.collector().refresh(at: 100, wall: base)
    let x = try #require(row(first, in: "x")), y = try #require(row(first, in: "y"))
    let again = await s.collector().refresh(at: 100, wall: base)
    #expect(row(again, in: "x")?.monitor.key == x.monitor.key && row(again, in: "y")?.monitor.key == y.monitor.key)
    // The same folders under swapped processes, as after restarting both in the other order.
    try s.process(4242, in: "y")
    try s.process(4343, in: "x")
    let swapped = await s.collector().refresh(at: 100, wall: base)
    #expect(row(swapped, in: "x")?.process?.pid == 4343)
    #expect(row(swapped, in: "x")?.monitor.key == x.monitor.key && row(swapped, in: "y")?.monitor.key == y.monitor.key)
}

@Test func K20AProcessThatMovesFolderStopsReadingItsOldTranscript() async throws {
    let s = try ClaudeSandbox()
    try s.write(s.user(0) + s.assistant("m1", 4, output: 50))
    let collector = s.collector()
    _ = await collector.refresh(at: 100, wall: base)
    try s.writeTranscript(s.user(0) + s.assistant("m2", 4, output: 70), in: "y")
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 5_000), in: "y", finished: false, modified: base)
    try s.process(4242, in: "y")
    let moved = await collector.refresh(at: 101, wall: base)
    let parent = try #require(row(moved, in: "y"))
    #expect(parent.monitor.key.threadID == sessionID)                                    // no second transcript is live
    #expect(parent.monitor.counter.baseline?.outputTokens == 70)
    // What that transcript already holds is history: it must not reach the charts as new output.
    let sub = try #require(child(of: moved))
    #expect(sub.monitor.counter.baseline?.outputTokens == 5_000)
    #expect(try sub.monitor.workAverageRate(at: 101) == nil)
}

@Test func K21SubagentsStayWithTheirOwnTranscriptEvenWhenTheirIDsRepeat() async throws {
    let s = try ClaudeSandbox()
    try s.continueInSecondFolder()
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s1", 9, output: 300), in: "x")
    try s.writeSubagent(s.subRecord("user", "", 5) + s.subRecord("assistant", "s2", 9, output: 900), in: "y")
    let snapshot = await s.collector().refresh(at: 100, wall: base)
    #expect(snapshot.sessions.count == 4)
    #expect(Set(snapshot.sessions.map(\.monitor.key)).count == 4)
    let x = try #require(row(snapshot, in: "x")), y = try #require(row(snapshot, in: "y"))
    #expect(x.subagentUsage?.outputTokens == 300 && y.subagentUsage?.outputTokens == 900)
    let subX = try #require(snapshot.sessions.first { $0.parentThreadID == x.monitor.key.threadID })
    let subY = try #require(snapshot.sessions.first { $0.parentThreadID == y.monitor.key.threadID })
    #expect(subX.monitor.counter.baseline?.outputTokens == 300 && subY.monitor.counter.baseline?.outputTokens == 900)
    #expect(subX.process?.pid == 4242 && subY.process?.pid == 4343)
}

@Test func K22ASurvivorGoesBackToThePlainIDWithoutAddingItsNeighboursUsage() async throws {
    let s = try ClaudeSandbox()
    try s.continueInSecondFolder()
    let collector = s.collector()
    let shared = try #require(row(await collector.refresh(at: 100, wall: base), in: "y"))
    try s.exit(4242)
    let alone = await collector.refresh(at: 101, wall: base)
    #expect(alone.sessions.count == 1)
    let survivor = try #require(row(alone, in: "y"))
    #expect(survivor.monitor.key.threadID == sessionID && survivor.id == "claude:" + sessionID)
    #expect(survivor.monitor.counter.baseline?.outputTokens == 70)
    try s.process(4242, in: "x")
    let back = try #require(row(await collector.refresh(at: 102, wall: base), in: "y"))
    #expect(back.monitor.key == shared.monitor.key && back.monitor.counter.baseline?.outputTokens == 70)
}
